#!/usr/bin/env bash
#
# Los dos limitadores de la pasarela (issue TFM-MIS-MEM/docs#83).
#
#   cors(2000) → rate-limiting(910) → space-auth(900) → account-rate-limit(890)
#
# Lo que se comprueba no es que existan, sino las tres propiedades de las que
# depende que sirvan para algo:
#
#   1. El limitador de abuso cuenta ANTES de autenticar, así que una inundación
#      de credenciales inventadas topa con él y no llega a `auth`. Mientras
#      estuvo detrás, 25 claves aleatorias con la cuota agotada daban cero 429 y
#      llegaban las 25.
#   2. Su contador no se puede rotar. Ni por X-Forwarded-For el de abuso, ni por
#      X-Account-Id el de cuenta.
#   3. Montar el limitador de cuenta donde no debe es un error visible y no un
#      contador que aparenta contar.
#
# Los números de estas rutas son bajos a propósito: agotar los 600 y 300 por
# minuto del despliegue exigiría cientos de peticiones dentro de una ventana
# fija, y esa es exactamente la prueba que rueda a mitad y falla un día de cada
# diez. La medición sobre los números y la ruta reales es `tests/medicion-83.sh`.
#
#   ./tests/rate-limit.sh
#
# Requiere Kong, auth y pricing levantados y la red tfm-network.
set -uo pipefail

cd "$(dirname "$0")/.."

PROXY=${PROXY:-http://localhost:8000}
ADMIN=${ADMIN:-http://localhost:8001}
TMP=$(mktemp -d)
FAILED=0

cleanup() {
  echo "→ restaurando la configuración del repositorio"
  curl -s -o /dev/null -X POST "$ADMIN/config" -F config=@kong.yml
  docker compose -f docker-compose.test.yml down >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

check() { # check <descripción> <esperado> <obtenido>
  if [ "$2" = "$3" ]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1"
    echo "      esperado: $2"
    echo "      obtenido: $3"
    FAILED=1
  fi
}

codigo()  { curl -s -o /dev/null -w '%{http_code}' "$@"; }
cabecera() { # cabecera <nombre> <curl args...>
  local nombre=$1; shift
  curl -s -D - -o /dev/null "$@" | grep -i "^$nombre:" | tr -d ' \r' | cut -d: -f2
}
auth_hits() { docker logs auth-service 2>&1 | grep -c 'validate-key'; }

# Devuelve "<cuenta>|<canal>|<rol>" de lo que el backend ha recibido de verdad.
#
# Va en una función y no en línea a propósito. Un programa de Python con un
# diccionario por comprensión dentro de un `$(...)` anidado en comillas dobles
# lo parte la EXPANSIÓN DE LLAVES de bash —hay una coma dentro de `{}`—, y el
# resultado es que el `curl` se ejecuta dos veces y Python no compila. Como el
# error se traga `2>/dev/null`, se manifiesta a distancia: un contador una vuelta
# por delante de lo que el test cree haber gastado.
visto() {
  python3 -c "
import json,sys
h = {k.lower(): v for k, v in json.load(sys.stdin)['headers'].items()}
print('|'.join([h.get('x-account-id','-'), h.get('x-auth-channel','-'),
                h.get('x-role','-')]))"
}

# Extrae un campo del cuerpo ErrorReport de la respuesta.
codigo_error() { python3 -c "import json,sys;print(json.load(sys.stdin).get('code','-'))"; }

echo "→ levantando el servicio de eco"
docker compose -f docker-compose.test.yml up -d >/dev/null

echo "→ publicando las rutas de prueba (kong.yml + tests/echo-route.yml)"
awk '/^plugins:$/ && !done { while ((getline line < "tests/echo-route.yml") > 0) print line; done=1 } { print }' \
  kong.yml > "$TMP/kong.test.yml"
curl -s -o /dev/null -X POST "$ADMIN/config" -F config=@"$TMP/kong.test.yml"
sleep 2

echo "→ creando una cuenta de prueba"
EMAIL="rl-$(date +%s)@example.com"
curl -s -X POST "$PROXY/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"Passw0rd!23\"}" > "$TMP/reg.json"
curl -s -X POST "$PROXY/v1/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"Passw0rd!23\"}" > "$TMP/login.json"
ACCOUNT=$(python3 -c "import json;print(json.load(open('$TMP/reg.json'))['accountId'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$TMP/login.json'))['token'])")

# ---------------------------------------------------------------------------
echo
echo "→ A. limitador de abuso: cuenta antes de autenticar (/v1/echo-flood, 5/min)"

# La ventana del limitador de abuso es fija y va por IP, de modo que dos
# ejecuciones seguidas dentro del mismo minuto encontrarían la cuota ya gastada
# por la anterior. En vez de dar por hecho que está limpia —que es como se
# fabrica un test que falla un día de cada diez— se consulta cuánta queda y, si
# no queda ninguna, se espera a que la ventana ruede. El bloque se calibra sobre
# lo que quede, así que el resultado no depende del estado de partida.
RESP=$(curl -s -D - -o /dev/null "$PROXY/v1/echo-flood")
if [ "$(printf '%s' "$RESP" | head -1 | awk '{print $2}')" = "429" ]; then
  ESPERA=$(printf '%s' "$RESP" | grep -i '^retry-after:' | tr -d ' \r' | cut -d: -f2)
  echo "  (ventana agotada por una ejecución anterior; se esperan $((ESPERA + 1))s)"
  sleep $((ESPERA + 1))
  RESP=$(curl -s -D - -o /dev/null "$PROXY/v1/echo-flood")
fi
QUEDAN=$(printf '%s' "$RESP" | grep -i '^ratelimit-remaining:' | tr -d ' \r' | cut -d: -f2)

# Sin credencial, el limitador cuenta y space-auth rechaza. Que la respuesta sea
# 401 y no 429 es lo correcto MIENTRAS quede cuota: es la prueba de que el
# cambio de orden no ha convertido «sin credencial» en «demasiadas peticiones».
A_CODES=""
for _ in $(seq 1 "$QUEDAN"); do A_CODES="$A_CODES$(codigo "$PROXY/v1/echo-flood")"; done
ESPERADO=""
for _ in $(seq 1 "$QUEDAN"); do ESPERADO="${ESPERADO}401"; done
check "las $QUEDAN peticiones sin credencial que caben responden 401 y consumen cuota" \
  "$ESPERADO" "$A_CODES"

check "la siguiente sin credencial ya es 429: la petición sin credencial SÍ cuenta" \
  "429" "$(codigo "$PROXY/v1/echo-flood")"

# El corazón de #83.
ANTES=$(auth_hits)
FLOOD=""
for _ in $(seq 1 10); do
  CLAVE=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  FLOOD="$FLOOD $(codigo "$PROXY/v1/echo-flood" -H "X-API-Key: $CLAVE")"
done
check "10 API KEY aleatorias con la cuota agotada: 10 × 429" \
  " 429 429 429 429 429 429 429 429 429 429" "$FLOOD"
check "ninguna de las 10 llegó a auth" \
  "0" "$(( $(auth_hits) - ANTES ))"

# La simétrica de la anterior: el contador de abuso tampoco se rota.
XFF=""
for i in 1 2 3 4 5; do
  XFF="$XFF $(codigo "$PROXY/v1/echo-flood" -H "X-Forwarded-For: 10.0.0.$i")"
done
check "rotar X-Forwarded-For no reinicia el contador de abuso" \
  " 429 429 429 429 429" "$XFF"

# Consecuencia asumida del cambio de orden, y por eso se fija: el limitador de
# abuso no mira credenciales, así que corta también al llamante legítimo.
check "con la cuota agotada, hasta una credencial válida recibe 429" \
  "429" "$(codigo "$PROXY/v1/echo-flood" -H "Authorization: Bearer $TOKEN")"

# ---------------------------------------------------------------------------
echo
echo "→ B. limitador de cuenta: no se evade falsificando X-Account-Id (/v1/echo, 5/min)"

# Lo primero, con el contador de esta ruta aún entero: por el camino legítimo no
# cambia nada. La petición llega al backend con la identidad que escribe la
# pasarela, y no con la que falsifica el cliente. Va aquí y no en el bloque D
# porque las peticiones de más abajo agotan el límite de esta ruta.
check "una petición autenticada sigue llegando al backend con su identidad" \
  "$ACCOUNT|frontend|CUSTOMER" \
  "$(curl -s "$PROXY/v1/echo" -H "Authorization: Bearer $TOKEN" -H "X-Account-Id: falsa" | visto)"

# Un solo juego de cabeceras, el del limitador de cuenta. Los dos limitadores
# usan los mismos nombres y esta petición atraviesa los dos.
PRIMERA=$(curl -s -D - -o /dev/null "$PROXY/v1/echo" -H "Authorization: Bearer $TOKEN")
UNO=$(printf '%s' "$PRIMERA" | grep -ic '^ratelimit-limit:')
LEGADO=$(printf '%s' "$PRIMERA" | grep -ic '^x-ratelimit-.*-minute:')
LIMITE=$(printf '%s' "$PRIMERA" | grep -i '^ratelimit-limit:' | tr -d ' \r' | cut -d: -f2)
check "sale un único RateLimit-Limit, y es el del limitador de cuenta" "1|5" "$UNO|$LIMITE"
check "no salen las X-RateLimit-*-Minute del limitador de abuso" "0" "$LEGADO"

# Van dos consumidas; el límite de la ruta es 5. Si el contador siguiera la
# cabecera del cliente, cada una de estas sería la primera de una cuenta nueva y
# no habría 429 jamás.
B_CODES=""
for i in 3 4 5 6; do
  B_CODES="$B_CODES $(codigo "$PROXY/v1/echo" -H "Authorization: Bearer $TOKEN" -H "X-Account-Id: falsa-$i")"
done
check "4 peticiones más rotando X-Account-Id: la 6ª topa con el límite" \
  " 200 200 200 429" "$B_CODES"

CUERPO=$(curl -s "$PROXY/v1/echo" -H "Authorization: Bearer $TOKEN" -H "X-Account-Id: falsa-7")
check "el 429 del limitador de cuenta cumple ErrorReport" \
  "RATE_LIMIT_EXCEEDED" \
  "$(printf '%s' "$CUERPO" | codigo_error)"

check "y trae Retry-After" \
  "si" \
  "$([ -n "$(cabecera retry-after "$PROXY/v1/echo" -H "Authorization: Bearer $TOKEN")" ] && echo si || echo no)"

# ---------------------------------------------------------------------------
echo
echo "→ C. montarlo donde no debe es un error visible (/v1/echo-misconfig)"

check "sin space-auth delante y sin cabecera: 500, no un contador por IP" \
  "500" "$(codigo "$PROXY/v1/echo-misconfig")"

# El caso que la ausencia de cabecera no cubre: si el plugin solo mirara la
# cabecera, aquí contaría el valor del cliente y respondería 200.
check "sin space-auth delante y CON la cabecera falsificada: 500 igualmente" \
  "500" "$(codigo "$PROXY/v1/echo-misconfig" -H "X-Account-Id: falsa")"

check "y el cuerpo lo dice" \
  "GATEWAY_MISCONFIGURED" \
  "$(curl -s "$PROXY/v1/echo-misconfig" | codigo_error)"

# ---------------------------------------------------------------------------
echo
echo "→ D. por el camino legítimo no cambia nada"

# Las cuatro públicas. Se envían cuerpos inválidos a propósito: se comprueba que
# la petición LLEGA al servicio —que responde su propio 400— y no que la corte
# la pasarela con un 401 o un 429. Además no tienen efecto lateral: no se crea
# ninguna cuenta ni se envía ningún correo.
check "POST /v1/auth/register llega al servicio" \
  "400" "$(codigo -X POST "$PROXY/v1/auth/register" -H 'Content-Type: application/json' -d '{}')"
check "POST /v1/auth/login llega al servicio" \
  "400" "$(codigo -X POST "$PROXY/v1/auth/login" -H 'Content-Type: application/json' -d '{}')"
check "POST /v1/auth/forgot-password llega al servicio" \
  "400" "$(codigo -X POST "$PROXY/v1/auth/forgot-password" -H 'Content-Type: application/json' -d '{}')"
check "POST /v1/pricing/webhooks/stripe llega al servicio" \
  "400" "$(codigo -X POST "$PROXY/v1/pricing/webhooks/stripe" -H 'Content-Type: application/json' -d '{}')"

# El preflight no lleva credenciales y cors (2000) lo termina antes que ningún
# limitador. Si algún día consumiera cuota, un panel activo dejaría sin servicio
# a su propia IP sin hacer una sola petición real.
# El cupo se lee en una ruta pública: ahí el único limitador es el de abuso, y
# su contador no está tapado por el del limitador de cuenta —que en /v1/echo ya
# está agotado y se queda clavado en cero—.
SONDA=/v1/auth/validate-key
REM_ANTES=$(cabecera ratelimit-remaining "$PROXY$SONDA")
for _ in 1 2 3; do
  curl -s -o /dev/null -X OPTIONS "$PROXY/v1/echo" \
    -H 'Origin: http://localhost:3001' -H 'Access-Control-Request-Method: POST'
done
REM_DESPUES=$(cabecera ratelimit-remaining "$PROXY$SONDA")
# Las dos sondas consumen una cada una; los tres preflights, ninguna.
check "3 preflights CORS no consumen cuota" \
  "1" "$(( REM_ANTES - REM_DESPUES ))"

check "el preflight sale sin cabeceras de limitador" \
  "0" "$(curl -s -D - -o /dev/null -X OPTIONS "$PROXY/v1/echo" \
          -H 'Origin: http://localhost:3001' -H 'Access-Control-Request-Method: POST' \
          | grep -ic '^ratelimit-\|^x-ratelimit-')"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "TODAS LAS COMPROBACIONES PASAN"
else
  echo "HAY COMPROBACIONES QUE FALLAN"
fi
exit "$FAILED"
