local typedefs = require "kong.db.schema.typedefs"

-- Plugin de autenticación de la pasarela.
--
-- Acepta las credenciales de los dos canales de consumo sobre los mismos
-- endpoints: el JWT del canal web, que se valida por firma sin consultar a
-- `auth`, y la API KEY del canal de API, que sí exige consultarlo. El canal no
-- aparece en la URL: se deduce del tipo de credencial presentada.
return {
  name = "space-auth",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Endpoint interno de `auth` que valida la API KEY. Se declara
          -- explícitamente en kong.yml; este valor por defecto solo cubre el
          -- despliegue de desarrollo.
          { auth_endpoint = {
              type = "string",
              default = "http://auth-service:3000/v1/auth/validate-key",
              required = true,
          } },

          -- Secreto compartido que acredita a la pasarela como componente
          -- interno ante `auth`. Viaja en la cabecera X-Internal-Secret, que el
          -- contrato exige junto a la propia API KEY.
          { internal_secret = {
              type = "string",
              required = true,
              referenceable = true,
          } },

          -- Clave de firma de los JWT que emite `auth`. La pasarela solo
          -- verifica; nunca firma.
          { jwt_secret = {
              type = "string",
              required = true,
              referenceable = true,
          } },

          -- Emisor esperado. Verificar la firma no basta: si `JWT_SECRET` se
          -- reutilizase para firmar cualquier otra cosa, un token ajeno con la
          -- misma clave pasaría por sesión válida.
          { jwt_issuer = {
              type = "string",
              default = "auth-microservice",
              required = true,
          } },

          -- Vigencia del veredicto positivo de validate-key. Fija la ventana de
          -- revocación del canal de API. No se deriva de `exp` del JWT: son dos
          -- credenciales distintas, y la vigencia del JWT es configurable en
          -- `auth` dentro de [5 min, 2 h].
          { cache_ttl = {
              type = "number",
              default = 60,
              between = { 0, 300 },
          } },

          -- Vigencia del veredicto negativo. Es una optimización de latencia y
          -- de disponibilidad, no un control de seguridad: la inundación con
          -- claves inventadas la cubre el límite de peticiones de la pasarela.
          -- Se mantiene corta para que una clave recién emitida no arrastre un
          -- rechazo previo.
          { negative_cache_ttl = {
              type = "number",
              default = 10,
              between = { 0, 300 },
          } },

          -- Tiempos de espera de la llamada a `auth`, en milisegundos. Agotarlos
          -- se trata como indisponibilidad, nunca como credencial inválida.
          { auth_timeout_ms = {
              type = "number",
              default = 2000,
              between = { 100, 10000 },
          } },
        },
      },
    },
  },
}
