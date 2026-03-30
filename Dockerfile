FROM kong:3.6.0-ubuntu

USER root

# Instalar dependencias adicionales si fuesen necesarias para Lua (ej. lua-resty-jwt)
RUN apt-get update && apt-get install -y git unzip && \
    luarocks install lua-resty-jwt

# Copiar el plugin a medida a la estructura interna de Kong
COPY plugins/space-auth /usr/local/share/lua/5.1/kong/plugins/space-auth

# Cambiar de nuevo al usuario kong por seguridad (Stateless y seguro)
USER kong
