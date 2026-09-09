#!/usr/bin/env bash
#
# Medición del issue TFM-MIS-MEM/docs#83 sobre el despliegue real.
#
# NO es un test y no afirma nada: mide y vuelca. El mismo script se ejecuta
# antes y después del cambio, de modo que las dos salidas son comparables sin
# que ninguna constante del script tenga que cambiar entre una y otra —agota la
# cuota hasta ver un 429, sea cual sea el número configurado—.
#
# Las afirmaciones deterministas viven en `tests/rate-limit.sh`, que ejerce el
# mecanismo sobre la ruta de eco con un límite bajo. Aquí se paga el precio de
# agotar la cuota real porque el cuerpo del PR necesita la evidencia sobre la
# ruta que se despliega, no sobre una de prueba.
#
#   ./tests/medicion-83.sh
#
# Deja la pasarela sin cupo para esa IP durante lo que reste del minuto en
# curso. Ejecutar al final, nunca antes de los otros scripts.
set -uo pipefail

PROXY=${PROXY:-http://localhost:8000}
PROBE=${PROBE:-/v1/auth/validate-key}          # pública: la corta request-termination (PRIORITY 2)
PROTECTED=${PROTECTED:-/v1/pricing/subscription/status}
KEYS=${KEYS:-25}
PAR=${PAR:-25}

codigo()   { curl -s -o /dev/null -w '%{http_code}' "$PROXY$PROBE"; }
retry()    { curl -s -D - -o /dev/null "$PROXY$PROBE" | grep -i '^retry-after:' | tr -d ' \r' | cut -d: -f2; }
auth_hits() { docker logs auth-service 2>&1 | grep -c 'validate-key'; }

# Dispara ráfagas contra la sonda pública hasta que responde 429. Devuelve por
# la salida estándar cuántas peticiones hicieron falta.
agotar() {
  local enviadas=0
  while [ "$(codigo)" != "429" ]; do
    seq 1 50 | xargs -P "$PAR" -I{} curl -s -o /dev/null "$PROXY$PROBE"
    enviadas=$((enviadas + 50))
    if [ "$enviadas" -gt 5000 ]; then
      echo "ABORTADO: 5000 peticiones sin ver un 429" >&2
      return 1
    fi
  done
  echo "$enviadas"
}

# ---------------------------------------------------------------------------
# Bloque opcional: los dos limitadores apilados sobre las rutas de credenciales.
#
# `auth` tiene un limitador propio —100 peticiones cada 15 minutos por IP, sobre
# `login`, `forgot-password` y `reset-password`—, de modo que esas tres rutas
# quedan con DOS limitadores en repositorios distintos. Se comprueba que el de
# `auth` sigue disparando con el de la pasarela por delante.
#
# Va tras una variable porque AGOTA EL PRESUPUESTO DE `auth` DURANTE 15 MINUTOS
# para esta IP: mientras dure, `login` responde 429 y ni este script ni
# `tests/rate-limit.sh` ni `tests/identity-headers.sh` pueden crear una sesión.
# Ejecutar solo cuando se quiera la evidencia, y en último lugar.
#
#   MEDIR_AUTH=1 ./tests/medicion-83.sh
if [ "${MEDIR_AUTH:-0}" = "1" ]; then
  echo "=== 0. limitadores apilados: el propio de auth sigue disparando ==="
  echo "  (auth limita a 100 cada 15 min; la pasarela, a 600 por minuto)"
  N=0
  CODE=000
  while [ "$N" -lt 200 ] && [ "$CODE" != "429" ]; do
    N=$((N + 1))
    # Cuerpo y código en UNA sola petición: dos curl por vuelta falsearían el
    # recuento del límite que se está midiendo.
    RESP=$(curl -s -w '\n%{http_code}' -X POST "$PROXY/v1/auth/login" \
             -H 'Content-Type: application/json' -d '{}')
    CODE=$(printf '%s' "$RESP" | tail -1)
    CUERPO=$(printf '%s' "$RESP" | sed '$d')
  done
  echo "  primer 429 en la petición nº $N"
  echo "  cuerpo: $CUERPO"
  # El de `auth` lleva `code`; el de Kong lleva `request_id` y no lleva `code`.
  if printf '%s' "$CUERPO" | grep -q 'request_id'; then
    echo "  → lo emite LA PASARELA (no lleva code, issue #82)"
  else
    echo "  → lo emite AUTH (cumple ErrorReport)"
  fi
  echo
fi

echo "=== 1. agotar la cuota de esta IP en la sonda pública $PROBE ==="
# Si la ventana está a punto de rodar no da tiempo a la fase 2. Hay que ESPERAR
# a que ruede: volver a llamar a `agotar` no sirve de nada, porque itera hasta
# ver un 429 y con la cuota ya gastada devuelve a la primera sin enviar ninguna
# —así salía un «0 peticiones hasta el 429» que no medía nada—.
for intento in 1 2 3; do
  ENVIADAS=$(agotar) || exit 1
  MARGEN=$(retry)
  [ "${MARGEN:-0}" -ge 20 ] && break
  echo "  ventana con solo ${MARGEN}s de margen; se espera a que ruede (intento $intento)"
  sleep $((MARGEN + 1))
done
if [ "${MARGEN:-0}" -lt 20 ]; then
  echo "ABORTADO: tres intentos sin conseguir una ventana con margen" >&2
  exit 1
fi
echo "  peticiones hasta el 429: $ENVIADAS"
echo "  margen de ventana: ${MARGEN}s"
echo -n "  sonda pública $PROBE -> "; codigo; echo
echo -n "  cabeceras del limitador: "
curl -s -D - -o /dev/null "$PROXY$PROBE" \
  | grep -iE '^(ratelimit|x-ratelimit|retry-after)' | tr -d '\r' | tr '\n' ' '; echo

ANTES=$(auth_hits)
echo "  líneas validate-key en el log de auth (antes): $ANTES"

echo
echo "=== 2. $KEYS API KEY aleatorias distintas contra $PROTECTED ==="
CODES=""
for _ in $(seq 1 "$KEYS"); do
  CLAVE=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  CODES="$CODES $(curl -s -o /dev/null -w '%{http_code}' "$PROXY$PROTECTED" -H "X-API-Key: $CLAVE")"
done
echo " códigos:$CODES"
for c in 429 401 503; do
  printf '  %s obtenidos: %s\n' "$c" "$(echo "$CODES" | tr ' ' '\n' | grep -c "^$c$")"
done

DESPUES=$(auth_hits)
echo "  líneas validate-key en el log de auth (después): $DESPUES  (nuevas: $((DESPUES-ANTES)))"

echo
echo "=== 3. la cuota seguía agotada al terminar (la ventana no rodó) ==="
echo -n "  sonda pública $PROBE -> "; codigo; echo
