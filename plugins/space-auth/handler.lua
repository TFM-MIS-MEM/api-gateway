-- Autenticación de la pasarela para los dos canales de consumo.
--
--   Authorization: Bearer <jwt>  → canal "frontend". Se valida por firma y por
--                                  emisor, sin consultar a `auth`.
--   X-API-Key: <clave>           → canal "api". Se valida contra
--                                  POST /v1/auth/validate-key, con caché corta.
--
-- Hacia el microservicio de destino se propaga la identidad ya resuelta en
-- X-Account-Id, X-Auth-Channel y X-Role. Esas tres cabeceras se borran SIEMPRE
-- antes de escribirlas: si llegasen del cliente y el plugin no las sobrescribiera
-- en algún camino, cualquiera suplantaría otra cuenta enviándolas a mano.

local jwt_parser = require "kong.plugins.jwt.jwt_parser"
local sha256_hex = require("kong.tools.sha256").sha256_hex
local http = require "resty.http"
local cjson = require "cjson.safe"

local kong = kong

local SpaceAuthHandler = {
  PRIORITY = 1000,
  VERSION = "2.0.0",
}

-- Cabeceras de identidad. Son propiedad exclusiva de la pasarela.
-- Authorization y X-API-Key NO están aquí: son credenciales del cliente y
-- viajan al backend tal cual.
local IDENTITY_HEADERS = {
  "X-Account-Id",
  "X-Auth-Channel",
  "X-Role",
}

local VALID_ROLES = {
  CUSTOMER = true,
  ADMIN    = true,
}

-- Patrón ERROR REPORT: el campo `code` distingue subtipos dentro de un mismo
-- código HTTP.
local function fail(status, code, message)
  return nil, { status = status, code = code, message = message }
end

-- ---------------------------------------------------------------------------
-- Canal web: JWT verificado por firma
-- ---------------------------------------------------------------------------
local function identity_from_jwt(conf, token)
  local jwt, err = jwt_parser:new(token)
  if err or type(jwt) ~= "table" then
    return fail(401, "INVALID_TOKEN", "The bearer token is malformed")
  end

  -- `auth` firma en HS256. Aceptar cualquier otro algoritmo abriría la vía de
  -- confusión de algoritmo: un token "none", o uno RS256 que haría pasar la
  -- clave simétrica por clave pública.
  if jwt.header.alg ~= "HS256" then
    return fail(401, "INVALID_TOKEN", "Unsupported token signing algorithm")
  end

  if not jwt:verify_signature(conf.jwt_secret) then
    return fail(401, "INVALID_TOKEN", "The bearer token signature is invalid")
  end

  local ok = jwt:verify_registered_claims({ "exp" })
  if not ok then
    return fail(401, "INVALID_TOKEN", "The bearer token has expired")
  end

  -- La firma sola no basta: `JWT_SECRET` es un único valor de configuración, y
  -- si alguna vez se reutilizase para firmar otra cosa —un enlace de
  -- recuperación, un token de servicio— este plugin lo aceptaría como sesión y
  -- propagaría el `sub` que llevara dentro.
  if jwt.claims.iss ~= conf.jwt_issuer then
    return fail(401, "INVALID_TOKEN", "The bearer token was not issued for this platform")
  end

  return {
    account_id = jwt.claims.sub,
    role       = jwt.claims.role,
    channel    = "frontend",
  }
end

-- ---------------------------------------------------------------------------
-- Canal de API: la API KEY se valida contra `auth`
-- ---------------------------------------------------------------------------

-- Devuelve el veredicto de `auth` para una clave. Se ejecuta dentro de
-- kong.cache:get, de modo que sus valores de retorno deciden qué se cachea:
--
--   veredicto, nil            → se guarda con `ttl` (60 s)
--   nil                       → se guarda como fallo con `neg_ttl` (10 s)
--   veredicto, nil, -1        → NO se guarda; mlcache 2.6.0 trata cualquier
--                               `new_ttl` negativo como "bypass cache"
--                               (kong/resty/mlcache/init.lua:694-698 y 906-909).
--
-- La indisponibilidad de `auth` usa esa tercera vía y no `nil, err`: con un
-- error, mlcache entra en la rama de resurrección (líneas 659-685) y devuelve
-- el veredicto rancio en lugar del error. Esa rama está armada —`kong.cache`
-- fija resurrect_ttl a 30 s por defecto en kong/cache/init.lua:109, porque la
-- clave de kong.conf se llama `db_resurrect_ttl` y `kong_config.resurrect_ttl`
-- llega nil—, así que servir el veredicto viejo con `auth` caído sería el
-- comportamiento por omisión, no una decisión.
local function fetch_verdict(conf, api_key)
  local httpc = http.new()
  httpc:set_timeouts(conf.auth_timeout_ms, conf.auth_timeout_ms, conf.auth_timeout_ms)

  local res, err = httpc:request_uri(conf.auth_endpoint, {
    method = "POST",
    headers = {
      ["Content-Type"]      = "application/json",
      ["X-API-Key"]         = api_key,
      ["X-Internal-Secret"] = conf.internal_secret,
    },
  })

  if not res then
    -- El mensaje del error de transporte no lleva la clave: solo destino y causa.
    kong.log.err("auth is unreachable at ", conf.auth_endpoint, ": ", err)
    return { unavailable = true }, nil, -1
  end

  if res.status >= 500 then
    kong.log.err("auth answered ", res.status, " while validating an API key")
    return { unavailable = true }, nil, -1
  end

  if res.status ~= 200 then
    -- Clave desconocida. Se cachea como fallo, con el TTL negativo.
    return nil
  end

  local body = cjson.decode(res.body)
  if type(body) ~= "table" or body.valid ~= true then
    return nil
  end

  return {
    account_id = body.accountId,
    -- El contrato declara `role` opcional en esta respuesta. Ausente, se asume
    -- el rol de menor privilegio.
    role       = body.role or "CUSTOMER",
    status     = body.status,
    channel    = "api",
  }
end

local function identity_from_api_key(conf, api_key)
  -- La clave nunca se usa como clave de caché en claro: quedaría legible en la
  -- memoria compartida de Kong y en cualquier volcado de diagnóstico.
  local cache_key = "space-auth:key:" .. sha256_hex(api_key)

  local verdict, err = kong.cache:get(cache_key, {
    ttl     = conf.cache_ttl,
    neg_ttl = conf.negative_cache_ttl,
  }, fetch_verdict, conf, api_key)

  if err then
    kong.log.err("could not resolve the API key verdict: ", err)
    return fail(503, "AUTH_UNAVAILABLE", "The authentication service is unavailable")
  end

  if verdict == nil then
    return fail(401, "INVALID_API_KEY", "The API key is invalid")
  end

  if verdict.unavailable then
    return fail(503, "AUTH_UNAVAILABLE", "The authentication service is unavailable")
  end

  -- Credencial válida sin permiso: es 403, no 401. Son casos distintos y el
  -- cliente actúa distinto ante cada uno.
  if verdict.status ~= "active" then
    return fail(403, "ACCOUNT_SUSPENDED", "This account is suspended")
  end

  return verdict
end

-- ---------------------------------------------------------------------------
function SpaceAuthHandler:access(conf)
  -- SANEADO. Incondicional y antes de cualquier bifurcación: ningún camino de
  -- salida de esta función —incluidos los `exit`— puede dejar pasar al backend
  -- una cabecera de identidad escrita por el cliente.
  for _, header in ipairs(IDENTITY_HEADERS) do
    kong.service.request.clear_header(header)
  end

  local identity, problem

  local token = kong.request.get_header("Authorization")
  local api_key = kong.request.get_header("X-API-Key")

  if token then
    -- El canal web se resuelve sin salir de la pasarela. Si el JWT viene, manda
    -- él: presentar además una API KEY no debe permitir elegir el veredicto más
    -- favorable de los dos.
    local prefix, value = token:match("^([Bb]earer)%s+(.+)$")
    if not prefix then
      problem = { status = 401, code = "INVALID_TOKEN",
                  message = "The Authorization header must use the Bearer scheme" }
    else
      identity, problem = identity_from_jwt(conf, value)
    end

  elseif api_key then
    identity, problem = identity_from_api_key(conf, api_key)

  else
    problem = { status = 401, code = "UNAUTHORIZED",
                message = "No credential was provided" }
  end

  -- GUARDA ÚNICA. Falla cerrado por construcción: la identidad tiene que estar
  -- completa y bien formada para que se escriba una sola cabecera. No depende
  -- de que cada rama se acuerde de comprobar su propio caso —un veredicto de
  -- servicio caído, un `sub` vacío o un rol inventado mueren todos aquí.
  if type(identity) ~= "table"
     or type(identity.account_id) ~= "string" or identity.account_id == ""
     or not VALID_ROLES[identity.role]
     or (identity.channel ~= "frontend" and identity.channel ~= "api")
  then
    problem = problem or { status = 401, code = "UNAUTHORIZED",
                           message = "The credential does not identify an account" }
    return kong.response.exit(problem.status,
                              { code = problem.code, message = problem.message })
  end

  kong.service.request.set_header("X-Account-Id", identity.account_id)
  kong.service.request.set_header("X-Auth-Channel", identity.channel)
  kong.service.request.set_header("X-Role", identity.role)
end

return SpaceAuthHandler
