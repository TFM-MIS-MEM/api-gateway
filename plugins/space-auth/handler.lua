local jwt = require "resty.jwt"
local SpaceAuthHandler = {
  PRIORITY = 1000, -- Prioridad de ejecución del plugin en la fase de 'access'
  VERSION = "1.0.0",
}

function SpaceAuthHandler:access(conf)
  -- 1. Extraer el token del header Authorization
  local auth_header = kong.request.get_header("Authorization")
  if not auth_header then
    return kong.response.exit(401, { message = "Falta el header Authorization" })
  end
  
  -- 2. Validar formato (Bearer XXX...)
  local token = auth_header:match("^Bearer%s+(.+)")
  if not token then
    return kong.response.exit(401, { message = "Formato de Authorization inválido, debe ser Bearer" })
  end

  -- 3. Aquí iría la lógica de decodificación y validación de JWT
  -- y validación del Pricing Token de SPACE en el Edge.
  -- Usamos lua-resty-jwt para validar la firma si quisiéramos.
  
  -- Ejemplo de mock para validación:
  -- local jwt_obj = jwt:verify(conf.jwt_secret, token)
  -- if not jwt_obj.verified then
  --   return kong.response.exit(401, { message = "Token inválido o expirado" })
  -- end
  
  -- local payload = jwt_obj.payload
  
  -- SIMULACIÓN DE PAYLOAD DESDE SPACE:
  local payload = {
    sub = "user_123",
    role = "CLIENT",
    space_quota_remaining = 500
  }

  -- 4. Inyección de Headers para los microservicios internos
  -- Si la validación es exitosa, se inyectan los datos del token en headers.
  -- Esto evita que el Backend tenga que re-validar o desencriptar el JWT entero.
  
  kong.service.request.set_header("X-User-Id", payload.sub)
  kong.service.request.set_header("X-User-Role", payload.role)
  kong.service.request.set_header("X-Space-Quota", tostring(payload.space_quota_remaining))
  
  kong.log.debug("Validación del Pricing Token de SPACE en Edge completada con éxito.")
end

return SpaceAuthHandler
