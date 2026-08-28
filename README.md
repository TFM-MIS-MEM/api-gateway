# api-gateway

Kong en modo *db-less*. Punto de entrada único de la plataforma: valida las
credenciales de ambos canales, aplica el límite general de peticiones y propaga
la identidad hacia los microservicios, que no son alcanzables por otra vía.

## Rutas

| Ruta | Servicio | Convención |
|---|---|---|
| `/v1/auth` | `auth-service:3000` | `/v1/{servicio}/...` |
| `/v1/pricing` | `pricing-service:3000` | `/v1/{servicio}/...` |

`strip_path: false` en todas: el microservicio recibe la ruta completa, la misma
que declara su especificación OpenAPI.

`GET /health` queda **fuera del versionado y fuera de la pasarela**: lo consumen
la sonda de Kubernetes y el `docker compose`, no los clientes de la API.

## Configuración y secretos

Los secretos no se escriben en `kong.yml`. Se referencian con el *vault* de
entorno de Kong:

```yaml
internal_secret: "{vault://env/space-auth-internal-secret}"
```

**El nombre del recurso se traduce a mayúsculas y los guiones a subrayados, sin
prefijo alguno** (`kong/vaults/env/init.lua`): `space-auth-internal-secret`
resuelve la variable `SPACE_AUTH_INTERNAL_SECRET`. No se usa el prefijo `KONG_`
a propósito: ese espacio de nombres es el de la configuración del propio Kong, y
una variable desconocida con ese prefijo provoca avisos de campo no reconocido
al arrancar.

> ⚠️ **El *vault* de entorno fotografía `environ` una sola vez, al inicializar
> el worker.** Cambiar una variable en `.env` y hacer `kong reload` **no** surte
> efecto: la recarga vuelve a leer `kong.yml`, pero no el entorno del proceso,
> que se hereda del contenedor. Hay que **recrear el contenedor**:
>
> ```sh
> docker compose -f docker-compose.dev.yml up -d --force-recreate kong
> ```
>
> Los cambios que solo tocan `kong.yml` sí se aplican con `kong reload`.

## Red

Todos los servicios comparten la red externa `tfm-network`, que es lo que
permite a Kong resolver `auth-service` y `pricing-service` por nombre:

```sh
docker network create tfm-network      # solo la primera vez
docker compose -f docker-compose.dev.yml up --build
```

Comprobación rápida:

```sh
docker exec kong-gateway getent hosts auth-service
```

## Puertos

| Puerto | Uso |
|---|---|
| 8000 | Proxy HTTP — `curl http://localhost:8000/v1/...` |
| 8443 | Proxy HTTPS |
| 8001 | Admin API — **solo desarrollo** |
| 8444 | Admin API HTTPS |
