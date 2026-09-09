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

# Aborta con ruido. Se usa para todo estado de partida o instrumento que no sea
# el previsto: un test que se adapta a lo que encuentre es un test que no puede
# fallar por esa vía, y entonces no vigila nada.
fatal() { # fatal <qué pasa> <detalle>
  echo "  ✗ ABORTA: $1"
  echo "      $2"
  FAILED=1
  exit 1
}
es_numero() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
estado()  { printf '%s' "$1" | head -1 | awk '{print $2}'; }
valcab()  { printf '%s' "$2" | grep -i "^$1:" | tr -d ' \r' | cut -d: -f2; }

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
APIKEY=$(python3 -c "import json;print(json.load(open('$TMP/reg.json'))['apiKey'])")

# ---------------------------------------------------------------------------
echo
echo "→ A. limitador de abuso: cuenta antes de autenticar (/v1/echo-flood, 5/min)"

# Antes que nada, que el instrumento esté vivo. Más abajo se comprueba que la
# inundación NO deja líneas nuevas en el registro de `auth`, y el valor esperado
# de esa comprobación es cero: si `docker logs` fallara —contenedor parado,
# renombrado, otro controlador de registro— las dos lecturas darían cero, la
# diferencia sería cero y la comprobación pasaría JUSTO cuando el instrumento
# está roto. Una llamada con una API KEY válida tiene que moverlo.
VIVO=$(auth_hits)
es_numero "$VIVO" || fatal "el recuento del registro de auth no es un número" "obtenido: '$VIVO'"
codigo "$PROXY/v1/pricing/subscription/status" -H "X-API-Key: $APIKEY" >/dev/null
MOVIDO=$(( $(auth_hits) - VIVO ))
[ "$MOVIDO" -ge 1 ] || fatal "el recuento del registro de auth no se mueve con una API KEY válida" \
  "una validación debería añadir al menos una línea; añadió $MOVIDO. Sin esto, la comprobación de la inundación no puede fallar."

# La ventana del limitador de abuso es fija y va por IP, de modo que dos
# ejecuciones seguidas dentro del mismo minuto encontrarían la cuota ya gastada
# por la anterior. Se espera a que ruede y se exige el estado EXACTO de partida:
# la sonda responde 401 y quedan justo LIMITE-1. No se calibra sobre lo que haya
# —adaptarse a cualquier estado convierte el bloque en un test que no puede
# fallar—; cualquier otra cosa aborta y dice cuál era.
LIMITE_FLOOD=5   # el declarado para esta ruta en tests/echo-route.yml

RESP=$(curl -s -D - -o /dev/null "$PROXY/v1/echo-flood")
CODE=$(estado "$RESP")
case "$CODE" in
  401|429) ;;
  *) fatal "la sonda a /v1/echo-flood responde $CODE" \
           "se esperaba 401 (queda cuota) o 429 (agotada). ¿Está publicada la ruta de prueba?" ;;
esac

DECLARADO=$(valcab ratelimit-limit "$RESP")
[ "$DECLARADO" = "$LIMITE_FLOOD" ] || fatal "el límite efectivo de /v1/echo-flood es $DECLARADO y no $LIMITE_FLOOD" \
  "tests/echo-route.yml y la constante LIMITE_FLOOD de este script han divergido"

QUEDAN=$(valcab ratelimit-remaining "$RESP")
es_numero "$QUEDAN" || fatal "la sonda no trae RateLimit-Remaining numérico" "obtenido: '$QUEDAN'"

# Estado de partida limpio = la sonda acaba de consumir la primera del minuto.
if [ "$QUEDAN" -ne $((LIMITE_FLOOD - 1)) ]; then
  RESET=$(valcab ratelimit-reset "$RESP")
  es_numero "$RESET" || fatal "no hay RateLimit-Reset numérico para esperar a la ventana" "obtenido: '$RESET'"
  [ "$RESET" -le 60 ] || fatal "RateLimit-Reset=$RESET fuera de la ventana de 60 s" "la configuración de la ruta no es la esperada"
  echo "  (quedan $QUEDAN de $LIMITE_FLOOD; se espera $((RESET + 1))s a que ruede la ventana)"
  sleep $((RESET + 1))
  RESP=$(curl -s -D - -o /dev/null "$PROXY/v1/echo-flood")
  CODE=$(estado "$RESP")
  QUEDAN=$(valcab ratelimit-remaining "$RESP")
  [ "$CODE" = "401" ] || fatal "tras esperar a la ventana la sonda responde $CODE y no 401" \
    "la ventana no ha rodado, o la ruta ha dejado de responder lo previsto"
  [ "$QUEDAN" = "$((LIMITE_FLOOD - 1))" ] || fatal "tras esperar a la ventana quedan $QUEDAN y no $((LIMITE_FLOOD - 1))" \
    "hay otro llamante consumiendo la cuota de esta IP; la medición no sería fiable"
fi

# Sin credencial, el limitador cuenta y space-auth rechaza. Que la respuesta sea
# 401 y no 429 es lo correcto MIENTRAS quede cuota: es la prueba de que el
# cambio de orden no ha convertido «sin credencial» en «demasiadas peticiones».
A_CODES=""
ESPERADO=""
for _ in $(seq 1 "$QUEDAN"); do
  A_CODES="$A_CODES$(codigo "$PROXY/v1/echo-flood")"
  ESPERADO="${ESPERADO}401"
done
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

LIMITE_ECHO=5   # el declarado para esta ruta en tests/echo-route.yml

# Misma exigencia que en el bloque A, por el mismo motivo: el contador de cuenta
# también va en ventana fija, y si rodara a mitad del bloque las respuestas
# dejarían de ser las previstas. Se exige el estado exacto de partida y margen
# suficiente para las siete peticiones que quedan; si no lo hay, se espera a que
# ruede. Nada de adaptarse a lo que haya.
sonda_echo() {
  curl -s -D "$TMP/cab" -o "$TMP/cuerpo" "$PROXY/v1/echo" \
    -H "Authorization: Bearer $TOKEN" -H "X-Account-Id: falsa"
}
estado_echo() {
  QUEDAN_E=$(valcab ratelimit-remaining "$(cat "$TMP/cab")")
  RESET_E=$(valcab ratelimit-reset "$(cat "$TMP/cab")")
  es_numero "$QUEDAN_E" || fatal "/v1/echo no trae RateLimit-Remaining numérico" "obtenido: '$QUEDAN_E'"
  es_numero "$RESET_E"  || fatal "/v1/echo no trae RateLimit-Reset numérico"     "obtenido: '$RESET_E'"
}

sonda_echo
estado_echo
if [ "$QUEDAN_E" -ne $((LIMITE_ECHO - 1)) ] || [ "$RESET_E" -lt 10 ]; then
  echo "  (quedan $QUEDAN_E de $LIMITE_ECHO con $RESET_E s de ventana; se espera $((RESET_E + 1))s)"
  sleep $((RESET_E + 1))
  sonda_echo
  estado_echo
  [ "$QUEDAN_E" -eq $((LIMITE_ECHO - 1)) ] || fatal "tras esperar a la ventana quedan $QUEDAN_E y no $((LIMITE_ECHO - 1))" \
    "el cupo de esta cuenta lo está gastando algo más; la medición no sería fiable"
  [ "$RESET_E" -ge 10 ] || fatal "tras esperar a la ventana solo quedan $RESET_E s" \
    "no hay margen para las peticiones del bloque"
fi

# Esa misma petición vale de comprobación del camino legítimo: llega al backend
# con la identidad que escribe la pasarela, no con la que falsifica el cliente.
check "una petición autenticada sigue llegando al backend con su identidad" \
  "$ACCOUNT|frontend|CUSTOMER" "$(visto < "$TMP/cuerpo")"

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
# Sin las dos lecturas, la resta daría cero y cero NO es el valor esperado, así
# que la comprobación fallaría; aun así se aborta explícitamente para que el
# motivo se lea en el sitio y no haya que deducirlo de un «esperado 1, obtenido 0».
es_numero "$REM_ANTES" && es_numero "$REM_DESPUES" \
  || fatal "las sondas de $SONDA no traen RateLimit-Remaining numérico" \
           "antes='$REM_ANTES' después='$REM_DESPUES'"
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
