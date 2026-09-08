local typedefs = require "kong.db.schema.typedefs"

-- Límite de peticiones por cuenta.
--
-- Se monta ÚNICAMENTE en rutas que lleven `space-auth`, porque cuenta sobre la
-- cabecera de identidad que ese plugin escribe. En una ruta sin él, la cabecera
-- falta y el plugin responde 500 en lugar de contar por dirección de origen en
-- silencio.
return {
  name = "account-rate-limit",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Peticiones por minuto y por cuenta. Provisional: la oferta comercial
          -- publica tasas POR SEGUNDO y POR PLAN (3/10, 5/50 y 20/200), que
          -- exigen conocer el plan de la cuenta. Ese es el issue I6; este valor
          -- es el sustrato sobre el que se monta.
          { minute = {
              type = "number",
              default = 300,
              required = true,
              between = { 1, 1000000 },
          } },

          -- Cabecera de la que sale el identificador de cuenta. Es configurable
          -- para poder ejercitarla en las pruebas, no para cambiarla en el
          -- despliegue: tiene que ser la misma que escribe `space-auth`.
          { header_name = {
              type = "string",
              default = "X-Account-Id",
              required = true,
          } },

          -- Diccionario compartido donde vive el contador. Kong OSS no permite
          -- declararlo desde el plugin: se inyecta como directiva de nginx con
          -- KONG_NGINX_HTTP_LUA_SHARED_DICT. Si falta, el plugin responde 500.
          --
          -- La política es LOCAL, por nodo. Con varias réplicas de Kong el
          -- límite efectivo se multiplica por el número de réplicas. Está
          -- recogido en I6, que lo pasa a Redis; no se cambia aquí.
          { dictionary_name = {
              type = "string",
              default = "account_rate_limit",
              required = true,
          } },
        },
      },
    },
  },
}
