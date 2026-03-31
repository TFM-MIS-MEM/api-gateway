FROM kong:3.6.0-ubuntu

USER root

# El custom plugin ahora utiliza el motor nativo de JWT del propio Kong
# por lo que evitamos descargar dependencias externas problemáticas de LuaRocks.
COPY plugins/space-auth /usr/local/share/lua/5.1/kong/plugins/space-auth

# Cambiar de nuevo al usuario kong por seguridad (Stateless y seguro)
USER kong
