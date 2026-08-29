#!/usr/bin/env bash
#
# Prueba de extremo a extremo del saneado de cabeceras de identidad.
#
# Que la pasarela borre las cabeceras que envía el cliente no es observable
# desde fuera: hace falta un backend que devuelva lo que recibe. Es el control
# de seguridad cuyo fallo es más silencioso —una regresión no rompe ninguna
# funcionalidad—, así que se comprueba con un test y no a mano.
#
#   ./tests/identity-headers.sh
#
# Requiere Kong, auth y pricing levantados y la red tfm-network.
set -euo pipefail

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

echo "→ levantando el servicio de eco"
docker compose -f docker-compose.test.yml up -d >/dev/null

echo "→ publicando la ruta de eco (kong.yml + tests/echo-route.yml)"
# La ruta vive solo en la configuración empujada: kong.yml no la menciona.
awk '/^plugins:$/ && !done { while ((getline line < "tests/echo-route.yml") > 0) print line; done=1 } { print }' \
  kong.yml > "$TMP/kong.test.yml"
curl -s -o /dev/null -X POST "$ADMIN/config" -F config=@"$TMP/kong.test.yml"
sleep 2

echo "→ creando una cuenta de prueba"
EMAIL="e2e-$(date +%s)@example.com"
curl -s -X POST "$PROXY/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"Passw0rd!23\"}" > "$TMP/reg.json"
curl -s -X POST "$PROXY/v1/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"Passw0rd!23\"}" > "$TMP/login.json"

ACCOUNT=$(python3 -c "import json;print(json.load(open('$TMP/reg.json'))['accountId'])")
APIKEY=$(python3 -c "import json;print(json.load(open('$TMP/reg.json'))['apiKey'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$TMP/login.json'))['token'])")

# Devuelve "<account>|<channel>|<role>|<credenciales presentes>" de lo que el
# backend ha recibido de verdad.
seen() {
  python3 -c "
import json,sys
h = {k.lower(): v for k, v in json.load(sys.stdin)['headers'].items()}
creds = ','.join(sorted(c for c in ('authorization', 'x-api-key') if c in h))
print('|'.join([h.get('x-account-id','-'), h.get('x-auth-channel','-'),
                h.get('x-role','-'), creds or '-']))"
}

FORGED=(-H "X-Account-Id: cuenta-de-otro" -H "X-Auth-Channel: api" -H "X-Role: ADMIN")

echo "→ comprobaciones"

check "el JWT manda sobre las cabeceras que falsifica el cliente" \
  "$ACCOUNT|frontend|CUSTOMER|authorization" \
  "$(curl -s -X POST "$PROXY/v1/echo" -H "Authorization: Bearer $TOKEN" "${FORGED[@]}" | seen)"

check "la API KEY manda sobre las cabeceras que falsifica el cliente" \
  "$ACCOUNT|api|CUSTOMER|x-api-key" \
  "$(curl -s -X POST "$PROXY/v1/echo" -H "X-API-Key: $APIKEY" "${FORGED[@]}" | seen)"

check "una ruta sin space-auth borra las tres cabeceras" \
  "-|-|-|-" \
  "$(curl -s -X POST "$PROXY/v1/echo-public" "${FORGED[@]}" | seen)"

check "sin credencial, la petición no llega al backend" \
  "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROXY/v1/echo" "${FORGED[@]}")"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "TODAS LAS COMPROBACIONES PASAN"
else
  echo "HAY COMPROBACIONES QUE FALLAN"
fi
exit "$FAILED"
