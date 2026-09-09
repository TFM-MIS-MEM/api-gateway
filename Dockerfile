FROM kong:3.6.0-ubuntu

USER root

# El custom plugin ahora utiliza el motor nativo de JWT del propio Kong
# por lo que evitamos descargar dependencias externas problemáticas de LuaRocks.
COPY plugins/space-auth /usr/local/share/lua/5.1/kong/plugins/space-auth

# Limitador por cuenta. Corre detrás de space-auth y cuenta sobre la cabecera de
# identidad que aquel escribe. Necesita el diccionario compartido que declaran
# los compose con KONG_NGINX_HTTP_LUA_SHARED_DICT.
COPY plugins/account-rate-limit /usr/local/share/lua/5.1/kong/plugins/account-rate-limit

# Cambiar de nuevo al usuario kong por seguridad (Stateless y seguro)
USER kong
