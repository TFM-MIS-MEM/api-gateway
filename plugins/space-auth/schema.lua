local typedefs = require "kong.db.schema.typedefs"

return {
  name = "space-auth",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Endpoint interno del microservicio de Auth para validar la API KEY
          { auth_endpoint = { type = "string", default = "http://auth-service:3000/api/v1/auth/internal/validate-api-key" } },
          -- Secreto interno para comunicación M2M
          { internal_secret = { type = "string", required = true } },
          -- Secretos de SPACE para verificar la firma del Pricing Token
          { jwt_secret = { type = "string", required = true } },
          { jwt_salt = { type = "string", required = true } }
        },
      },
    },
  },
}