# api-gateway

Kong en modo *db-less*. Punto de entrada único de la plataforma: valida las
credenciales de ambos canales, aplica el límite general de peticiones y propaga
la identidad hacia los microservicios, que no son alcanzables por otra vía.

## Rutas

| Ruta | Destino | Autenticación |
|---|---|---|
| `/v1/auth/validate-key` | — | cortada con `404`: es de uso interno de la pasarela y su contrato prohíbe exponerla |
| `/v1/auth` | `auth-service:3000` | ninguna. El registro y el inicio de sesión son públicos, y las operaciones de cuenta las protege el propio servicio |
| `/v1/pricing/webhooks/stripe` | `pricing-service:3000` | ninguna. El evento se autentica con su propia firma, que valida el servicio |
| `/v1/pricing` | `pricing-service:3000` | `space-auth` |

`strip_path: false` en las cuatro: el microservicio recibe la ruta completa, la
misma que declara su especificación OpenAPI.

Las rutas más largas ganan la resolución sobre las más cortas, que es lo que
permite que `/v1/auth/validate-key` y el receptor de Stripe se traten aparte sin
sacarlos del prefijo de su servicio.

## Autenticación — plugin `space-auth`

Acepta las credenciales de los dos canales sobre los mismos endpoints. El canal
no aparece en la URL: se deduce de la credencial presentada.

| Credencial | Canal | Validación |
|---|---|---|
| `Authorization: Bearer <jwt>` | `frontend` | firma HS256 **y** `iss`, en la propia pasarela. No se consulta a `auth` |
| `X-API-Key` | `api` | `POST /v1/auth/validate-key`, con caché de 60 s |

Hacia el backend se propaga `X-Account-Id`, `X-Auth-Channel` y `X-Role`. **Esas
tres cabeceras se borran siempre antes de escribirse**, y en las rutas que no
llevan el plugin las borra un `request-transformer`: el saneado es propiedad de
la pasarela, no del plugin, porque si no cualquiera suplantaría una cuenta
enviándolas a mano. `Authorization` y `X-API-Key` viajan intactas.

Respuestas propias de la pasarela, con el cuerpo del patrón *Error Report*:

| Código | Cuándo |
|---|---|
| `401` | sin credencial, o credencial inválida |
| `403` | credencial válida de cuenta suspendida |
| `503` | `auth` inalcanzable al validar una API KEY |

Que esas respuestas no las declare el contrato de los servicios está recogido en
`TFM-MIS-MEM/docs#68`.

Verificar el emisor además de la firma no es redundante: `JWT_SECRET` es un
único valor de configuración, y si alguna vez firmara otra cosa —un enlace de
recuperación, un token de servicio—, un plugin que solo comprobara la firma lo
aceptaría como sesión y propagaría el `sub` que llevase dentro.

**El canal web sobrevive a una caída de `auth` y el canal de API no.** Es
consecuencia directa del diseño: con `auth` parado, un JWT válido sigue pasando
—se verifica por firma— y una API KEY recibe `503`. Ese es el precio de no
consultar al servicio en cada petición, y su contrapartida es la ventana de
revocación de hasta 60 minutos del JWT.

## Pruebas de extremo a extremo

`tests/cors-preflight.sh` comprueba el preflight CORS de las cuatro rutas sin
tocar la configuración. Un preflight no lleva credenciales: si el plugin de
autenticación se ejecutara antes que el de CORS lo respondería con `401` y
ningún navegador podría llamar a la API, aunque desde la terminal todo pareciera
correcto. Fija además que `X-API-Key` **no** está entre las cabeceras
permitidas, para que revertir esa decisión sea deliberado.

`docker-compose.test.yml` levanta `echo-service`, que devuelve las cabeceras que
recibe. Es lo que permite comprobar que la pasarela borra las cabeceras de
identidad del cliente y escribe las suyas. Su ruta de Kong no vive en
`kong.yml`: se empuja por la Admin API y se restaura al terminar. El
procedimiento está en la cabecera de ese fichero.

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
