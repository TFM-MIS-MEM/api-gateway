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
| `/v1/pricing` | `pricing-service:3000` | `space-auth` + `account-rate-limit` |

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

## Límite de peticiones — dos limitadores

Son dos problemas distintos, abuso y economía, y quieren dos contadores con
claves, números y posiciones distintas. La cadena efectiva es:

```
cors(2000) → rate-limiting(910) → space-auth(900) → account-rate-limit(890) → backend
```

| | Limitador de abuso | Limitador de cuenta |
|---|---|---|
| Plugin | `rate-limiting` de Kong, global | `account-rate-limit`, propio |
| Posición | **antes** de autenticar | **después** de autenticar |
| Clave | dirección de origen (`limit_by: ip`) | `X-Account-Id`, la que escribe la pasarela |
| Número | 600/min | 300/min |
| Montaje | global, toda ruta que case | solo rutas con `space-auth` |
| Protege | a `auth` y a la pasarela | el modelo de negocio |
| Naturaleza | operacional | económica |
| Almacenamiento | `policy: local` | diccionario compartido local |

**Por qué el de abuso va delante.** Hasta el issue
[`TFM-MIS-MEM/docs#83`](https://github.com/TFM-MIS-MEM/docs/issues/83) iba
detrás, y el efecto era que una petición sin credencial válida moría en
`space-auth` sin consumir cuota. Medido sobre el despliegue: con la cuota global
ya agotada, 25 API KEY aleatorias distintas contra una ruta protegida producían
**cero `429`** y llegaban las 25 hasta `auth` —cada clave tiene un resumen
distinto, luego una entrada de caché distinta, de modo que la caché negativa no
absorbe nada y cada petición es una consulta a Mongo—. Con el orden actual, las
25 reciben `429` y ninguna llega.

**Consecuencia asumida.** El limitador de abuso no mira credenciales, así que con
la cuota de una IP agotada, una petición sin credencial recibe `429` donde antes
recibía `401`, y una petición legítima también. Es el precio de contar antes de
autenticar. Las 46 operaciones alcanzables por la pasarela declaran `429` desde
el issue #68, de modo que no hay cambio de contrato.

**Ninguno de los dos contadores se puede rotar**, y las dos afirmaciones están
fijadas con un test:

- El de abuso usa `kong.client.get_forwarded_ip()`, que solo hace caso de
  `X-Forwarded-For` si el emisor está en `trusted_ips`. **`KONG_TRUSTED_IPS` se
  deja sin configurar a propósito**: declararla convertiría la clave del
  contador en un valor que escribe el cliente.
- El de cuenta lee `X-Account-Id`, que solo es de fiar porque `space-auth` la
  borra incondicionalmente y la reescribe antes. Montado por delante, contaría
  la del cliente. Para que eso no pueda pasar por descuido, `space-auth` deja
  constancia en `kong.ctx.shared` de que ha resuelto la identidad y
  `account-rate-limit` la exige: sin ella responde `500 GATEWAY_MISCONFIGURED`
  en lugar de contar. El `rate-limiting` de Kong, en su lugar, caería a la IP en
  silencio —`get_identifier` termina en `or kong.client.get_forwarded_ip()`—,
  que es un límite que aparenta contar y no cuenta.

**Un solo juego de cabeceras.** Los dos limitadores usan los mismos nombres, y
una petición autenticada atraviesa los dos. Gana el de cuenta, que es el cupo
sobre el que el cliente puede actuar: `account-rate-limit` reescribe
`RateLimit-Limit`, `-Remaining` y `-Reset` y borra las `X-RateLimit-*-Minute`
heredadas del de abuso. En las rutas públicas, donde solo corre el de abuso,
salen las suyas sin tocar.

**Dos cuerpos de `429` distintos, y es deliberado.** El de `account-rate-limit`
cumple *Error Report* con `code: RATE_LIMIT_EXCEEDED`. El del `rate-limiting` de
Kong **no lleva `code`**: lo construye formateando una plantilla de nodo con dos
huecos, mensaje e identificador de petición, y no hay hueco para más. Se sigue en
`TFM-MIS-MEM/docs#82` y no se arregla aquí; que el propio sí lo cumpla estrecha
esa divergencia en lugar de cerrarla.

### Limitaciones conocidas, que hereda I6

Los números y la mecánica de este sustrato son provisionales. Lo que I6 tiene que
resolver, y que aquí solo queda anotado:

- **Ventana fija alineada al reloj** en los dos limitadores: admite una ráfaga
  del doble del límite a caballo del borde de la ventana. Lo corrige una ventana
  deslizante.
- **Almacenamiento local**, por nodo. El contador es compartido entre los
  procesos de trabajo de un mismo Kong, pero **con varias réplicas el límite
  efectivo se multiplica por el número de réplicas**. Hay que pasar a Redis
  antes de que los números signifiquen algo.
- **Los números no son los de la oferta.** El pricing publica tasas **por
  segundo y por plan** —3/10, 5/50 y 20/200—, y aplicarlas exige conocer el plan
  de la cuenta, que la pasarela hoy no evalúa. Los 600 y 300 por minuto de este
  sustrato quedan **muy por debajo** de lo publicado: 600/min son 10/s, de modo
  que un cliente Business haciendo gestión a su tasa publicada de 200/s toparía
  con el limitador de abuso al 5 % de lo que ha contratado. Hoy no lo nota nadie
  porque nada aplica planes, pero reconciliar un limitador **previo a la
  autenticación** con tasas que dependen del plan es precisamente el trabajo de
  I6: el de abuso no puede conocer el plan, porque corre antes de saber quién
  llama.
- **`auth` tiene además su propio limitador**, de 100 peticiones cada 15 minutos
  por IP, montado sobre `login`, `forgot-password` y `reset-password`. Esas tres
  rutas quedan con **dos limitadores en repositorios distintos**. No se pisan: el
  de `auth` equivale a 6,7 peticiones por minuto sostenidas, muy por debajo de
  las 600 de la pasarela, así que es el suyo el que muerde primero y el de la
  pasarela solo acota la ráfaga dentro de un minuto.

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

`tests/rate-limit.sh` cubre los dos limitadores: que el de abuso cuenta antes de
autenticar y corta la inundación de credenciales inventadas sin que llegue a
`auth`, que ninguno de los dos contadores se rota, que montar el de cuenta sin
`space-auth` delante es un `500` y no un contador silencioso, que sale un solo
juego de cabeceras y que por el camino legítimo no cambia nada. Ejercita el
mecanismo sobre rutas de eco con límites de 5 por minuto: agotar los 600 y 300
reales exigiría cientos de peticiones dentro de una ventana fija, que es como se
fabrica un test que falla un día de cada diez. El bloque del limitador de abuso
**se calibra sobre la cuota que encuentre**, de modo que dos ejecuciones
seguidas dentro del mismo minuto dan el mismo resultado.

`tests/medicion-83.sh` **no es un test y no afirma nada**: mide y vuelca. Es el
que se ejecuta sobre los números y la ruta reales, y el mismo script produce el
«antes» y el «después» porque agota la cuota hasta ver un `429`, sea cual sea el
número configurado. Deja la pasarela sin cupo para esa IP durante lo que reste
del minuto, así que va el último.

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
