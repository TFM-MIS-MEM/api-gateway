local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local http = require "resty.http"
local cjson = require "cjson.safe"

local SpaceAuthHandler = {
  PRIORITY = 1000, 
  VERSION = "1.0.0",
}

function SpaceAuthHandler:access(conf)
  -- 1. Extraer la API KEY de la cabecera (usaremos 'X-API-Key' como estándar)
  local api_key = kong.request.get_header("X-API-Key")
  if not api_key then
    return kong.response.exit(401, { message = "No se ha proporcionado la API KEY en la cabecera X-API-Key" })
  end
  
  -- 2. Llamada interna al Microservicio de Auth para validar la API KEY
  local httpc = http.new()
  local res, err = httpc:request_uri(conf.auth_endpoint, {
    method = "POST",
    body = cjson.encode({ apiKey = api_key }),
    headers = {
      ["Content-Type"] = "application/json",
      ["x-internal-secret"] = conf.internal_secret,
    },
    keepalive_timeout = 60000,
    keepalive_pool = 10
  })

  if not res then
    kong.log.err("Error al contactar con el servicio de Auth: ", err)
    return kong.response.exit(500, { message = "Error interno del API Gateway" })
  end

  if res.status ~= 200 then
    return kong.response.exit(401, { message = "API KEY inválida o suspendida" })
  end

  -- Se asume que Auth devuelve un JSON con el Pricing Token de SPACE válido para este usuario
  local auth_body = cjson.decode(res.body)
  if not auth_body or not auth_body.pricing_token then
    kong.log.err("El microservicio de Auth no devolvió un pricing_token")
    return kong.response.exit(500, { message = "Error en la propagación de identidad" })
  end

  local token = auth_body.pricing_token

  -- 3. Validación de la firma del Pricing Token de SPACE en el Edge
  -- SPACE utiliza una combinación de secret + salt para firmar sus JWTs
  local combined_secret = conf.jwt_secret .. conf.jwt_salt
  
  local jwt_obj, err = jwt_decoder:new(token)
  if err or type(jwt_obj) ~= "table" then
    kong.log.err("Error al parsear token: ", err)
    return kong.response.exit(403, { message = "Pricing Token estructuralmente inválido" })
  end

  if not jwt_obj:verify_signature(combined_secret) then
    kong.log.err("Firma de Pricing Token inválida")
    return kong.response.exit(403, { message = "Pricing Token inválido o manipulado" })
  end
  
  local payload = jwt_obj.claims

  -- 4. Inyección de Headers para los microservicios internos (Reconocimiento Facial)
  -- Extraemos los datos clave del token de SPACE (asumiendo la estructura estándar de pricing4ts)
  kong.service.request.set_header("X-User-Id", payload.sub or auth_body.user_id)
  
  -- Si el token incluye un snapshot de límites, lo pasamos al backend para que actúe en consecuencia
  if payload.limits then
     -- Serializamos los límites en JSON simple para que FastAPI/Python lo lea fácilmente
    kong.service.request.set_header("X-Space-Limits", cjson.encode(payload.limits))
  end
  
  if payload.features then
    kong.service.request.set_header("X-Space-Features", cjson.encode(payload.features))
  end
  
  kong.log.debug("Validación de Auth y Pricing Token (SPACE) completada con éxito.")
end

return SpaceAuthHandler