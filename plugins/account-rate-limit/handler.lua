-- Límite de peticiones por cuenta.
--
-- Es el segundo de los dos limitadores de la pasarela, y el que aplicará las
-- tasas por plan cuando exista la evaluación de plan (issue I6). El primero
-- —`rate-limiting` de Kong, global, `limit_by: ip`— va DELANTE de la
-- autenticación y contiene la inundación; éste va DETRÁS y cuenta por cuenta.
--
--   cors(2000) → rate-limiting(910) → space-auth(900) → account-rate-limit(890)
--
-- La posición no es una preferencia: es lo que hace que el contador sea sólido.
-- La cuenta se lee de `X-Account-Id`, y esa cabecera solo es de fiar porque
-- `space-auth` la borra incondicionalmente y la reescribe antes de que este
-- plugin corra. Montado por delante de `space-auth`, contaría el valor que
-- envía el cliente y bastaría rotarlo para evadir el límite.
--
-- El accesor importa. `kong.request.get_header` resuelve por `ngx.var.http_*`
-- (kong/tools/http.lua:534) y no por la tabla de cabeceras, así que ver el
-- valor de la pasarela y no el del cliente depende de que `ngx.req.set_header`
-- actualice esa variable. Se comprobó midiendo, no leyendo, y es el mismo
-- accesor que usa el `rate-limiting` de Kong (`get_identifier`, líneas 70-71):
-- por eso la medición vale para los dos. Cambiarlo por `ngx.req.get_headers()`
-- exige repetir la comprobación.

local kong = kong
local ngx = ngx
local floor = math.floor

local AccountRateLimitHandler = {
  PRIORITY = 890,
  VERSION = "1.0.0",
}

-- El juego estándar. Se reescribe entero para que la respuesta lleve el del
-- limitador de cuenta y no el del de abuso, que corrió antes y ya escribió el
-- suyo: los dos usan estos mismos nombres.
local RATELIMIT_LIMIT     = "RateLimit-Limit"
local RATELIMIT_REMAINING = "RateLimit-Remaining"
local RATELIMIT_RESET     = "RateLimit-Reset"
local RETRY_AFTER         = "Retry-After"

-- Las heredadas que escribe el limitador de abuso. Se borran aquí: dejarlas
-- publicaría dos cupos distintos en la misma respuesta, y el cliente no tiene
-- forma de saber cuál le aplica.
local LEGACY = {
  "X-RateLimit-Limit-Minute",
  "X-RateLimit-Remaining-Minute",
}

local WINDOW = 60

local function misconfigured(message)
  kong.log.err("account-rate-limit: ", message)
  return kong.response.exit(500, {
    code    = "GATEWAY_MISCONFIGURED",
    message = "The gateway is misconfigured",
  })
end

function AccountRateLimitHandler:access(conf)
  -- Sin cuenta no se cuenta por dirección de origen. El `rate-limiting` de Kong
  -- sí lo hace —`get_identifier` termina en `or kong.client.get_forwarded_ip()`—
  -- y ese respaldo es justo el fallo silencioso que hay que evitar: montado por
  -- error en una ruta sin `space-auth`, el limitador seguiría respondiendo 200 y
  -- contando por IP, de modo que aparentaría contar por cuenta sin hacerlo.
  -- Falla ruidoso y visible en su lugar.
  -- Primero, que `space-auth` haya corrido de verdad en ESTA petición. La
  -- cabecera sola no lo demuestra: en una ruta sin `space-auth`, la que llega
  -- es la del cliente, y contar por ella sería contar por un valor que el
  -- llamante rota a voluntad. Exigir la marca de contexto convierte esa
  -- configuración incorrecta en un 500 visible en lugar de un límite que
  -- aparenta contar.
  local resuelta = kong.ctx.shared.space_auth_account_id
  if type(resuelta) ~= "string" or resuelta == "" then
    return misconfigured("space-auth did not resolve an identity for this request; " ..
                         "this plugin must be mounted only on routes that carry it")
  end

  local account = kong.request.get_header(conf.header_name)
  if type(account) ~= "string" or account == "" then
    return misconfigured("no " .. conf.header_name ..
                         " on the request; this plugin must run after space-auth")
  end

  -- Y que sean el mismo valor. Hoy es redundante —`space-auth` escribe los dos—
  -- pero deja de serlo en cuanto se intercale cualquier plugin entre los dos con
  -- prioridad entre 900 y 890 que toque la cabecera.
  if account ~= resuelta then
    return misconfigured("the " .. conf.header_name .. " header does not match the " ..
                         "identity space-auth resolved; a plugin in between rewrote it")
  end

  local dict = ngx.shared[conf.dictionary_name]
  if not dict then
    return misconfigured("the shared dictionary '" .. conf.dictionary_name ..
                         "' is not declared; see KONG_NGINX_HTTP_LUA_SHARED_DICT")
  end

  -- Ventana fija alineada al reloj, igual que la del limitador de abuso. Admite
  -- una ráfaga del doble del límite a caballo del borde —el final de una ventana
  -- y el principio de la siguiente—. Es una limitación conocida de la ventana
  -- fija y se corrige con la ventana deslizante de I6, no aquí.
  -- El ámbito va en la clave: todas las rutas que lo compartan comparten cupo.
  -- Un contador por ruta sería un límite económico que se evade repartiendo las
  -- llamadas entre endpoints.
  local now = ngx.time()
  local key = conf.scope .. ":" .. account .. ":" .. floor(now / WINDOW)

  -- El TTL de creación deja caducar la entrada sola: no hay que barrer nada, y
  -- el diccionario no crece con las cuentas que dejan de llamar.
  local count, err = dict:incr(key, 1, 0, WINDOW + 5)
  if not count then
    -- Sin contador no se inventa un veredicto: se deja pasar y se registra. Un
    -- diccionario lleno es un problema de capacidad de la pasarela, no una razón
    -- para rechazar tráfico legítimo; el limitador de abuso sigue delante.
    kong.log.err("account-rate-limit: could not count the request: ", err)
    return
  end

  local reset = WINDOW - (now % WINDOW)

  for _, header in ipairs(LEGACY) do
    kong.response.clear_header(header)
  end
  kong.response.set_header(RATELIMIT_LIMIT, conf.minute)
  kong.response.set_header(RATELIMIT_REMAINING, math.max(conf.minute - count, 0))
  kong.response.set_header(RATELIMIT_RESET, reset)

  if count > conf.minute then
    kong.response.set_header(RETRY_AFTER, reset)
    -- Patrón ERROR REPORT, igual que el resto de respuestas de la pasarela. El
    -- 429 del `rate-limiting` de Kong NO lo cumple —su plantilla de cuerpo no
    -- tiene hueco para `code`— y se sigue en el issue #82; que este sí lo
    -- cumpla estrecha esa divergencia, no la cierra.
    return kong.response.exit(429, {
      code    = "RATE_LIMIT_EXCEEDED",
      message = "API rate limit exceeded for this account",
    })
  end
end

return AccountRateLimitHandler
