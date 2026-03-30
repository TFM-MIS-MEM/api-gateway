local typedefs = require "kong.db.schema.typedefs"

return {
  name = "space-auth",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Aquí definimos los campos de configuración que el plugin aceptará en kong.yml
          { jwt_secret = { type = "string", required = false } },
          { space_public_key = { type = "string", required = false } }
        },
      },
    },
  },
}
