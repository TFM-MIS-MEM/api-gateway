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
# Requiere Kong, auth, pricing y fr-commercial levantados y la red tfm-network.
#
# La ruta de fr se comprueba dos veces. Primero con su upstream cambiado por el
# de eco y TODO lo demás intacto ---la ruta y sus plugins son los de kong.yml---,
# para ver las cabeceras que llegan. Después contra fr real, con kong.yml tal
# cual, para ver que una cuenta no alcanza las galerías de otra declarándose
# ella.
#
# KONG_YML permite ejecutar las comprobaciones contra otra configuración, por
# ejemplo una copia sin saneado para ver que el test sabe fallar. Al salir se
# restaura SIEMPRE kong.yml del repositorio, no la que se haya pasado.
#
#   KONG_YML=/ruta/a/copia.yml ./tests/identity-headers.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PROXY=${PROXY:-http://localhost:8000}
ADMIN=${ADMIN:-http://localhost:8001}
KONG_YML=${KONG_YML:-kong.yml}
TMP=$(mktemp -d)
FAILED=0

cleanup() {
  echo "→ restaurando la configuración del repositorio"
  curl -s -o /dev/null -X POST "$ADMIN/config" -F config=@kong.yml
  docker compose -f docker-compose.test.yml down >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Empuja una configuración y aborta si Kong no la acepta. Sin esto, un YAML que
# Kong rechaza deja puesta la configuración ANTERIOR y las comprobaciones
# siguientes se ejecutan contra ella sin que nada lo diga.
push() { # push <fichero>
  local status
  status=$(curl -s -o "$TMP/push.out" -w '%{http_code}' -X POST "$ADMIN/config" -F config=@"$1")
  if [ "$status" != "201" ]; then
    echo "  ✗ Kong rechazó $1 ($status): $(head -c 300 "$TMP/push.out")"
    exit 1
  fi
  sleep 2
}

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

echo "→ publicando la ruta de eco ($KONG_YML + tests/echo-route.yml, fr → eco)"
# La ruta vive solo en la configuración empujada: kong.yml no la menciona. El
# upstream de fr se sustituye por el de eco; la ruta y sus plugins no se tocan.
FR_UPSTREAM='url: http://fr-commercial-service:8000'
if [ "$(grep -c "$FR_UPSTREAM" "$KONG_YML")" != "1" ]; then
  echo "  ✗ $KONG_YML no declara una sola vez '$FR_UPSTREAM'"
  exit 1
fi
sed "s#$FR_UPSTREAM#url: http://echo-service:8080#" "$KONG_YML" \
  | awk '/^plugins:$/ && !done { while ((getline line < "tests/echo-route.yml") > 0) print line; done=1 } { print }' \
  > "$TMP/kong.test.yml"
push "$TMP/kong.test.yml"

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

FR=/v1/fr/commercial/galleries

# "<código>|<presente|ausente>" de X-Kong-Upstream-Latency: Kong solo la pone
# cuando ha llegado a hablar con el upstream.
upstream() {
  curl -s -D - -o /dev/null "$@" | python3 -c "
import sys
lines = sys.stdin.read().splitlines()
code = lines[0].split()[1] if lines else '000'
up = any(l.lower().startswith('x-kong-upstream-latency:') for l in lines)
print(code + '|' + ('presente' if up else 'ausente'))"
}

echo "→ ruta de fr (upstream → eco)"

check "fr · el JWT manda sobre las cabeceras que falsifica el cliente" \
  "$ACCOUNT|frontend|CUSTOMER|authorization" \
  "$(curl -s "$PROXY$FR" -H "Authorization: Bearer $TOKEN" "${FORGED[@]}" | seen)"

check "fr · la API KEY manda sobre las cabeceras que falsifica el cliente" \
  "$ACCOUNT|api|CUSTOMER|x-api-key" \
  "$(curl -s "$PROXY$FR" -H "X-API-Key: $APIKEY" "${FORGED[@]}" | seen)"

# Control de la comprobación siguiente: si una petición que SÍ llega tampoco
# llevara la cabecera, su ausencia no probaría nada.
check "fr · control: la petición autenticada llega al upstream" \
  "200|presente" \
  "$(upstream "$PROXY$FR" -H "Authorization: Bearer $TOKEN" "${FORGED[@]}")"

check "fr · sin credencial, 401 y la petición no llega al upstream" \
  "401|ausente" \
  "$(upstream "$PROXY$FR" "${FORGED[@]}")"

echo "→ ruta de fr contra fr real ($KONG_YML tal cual)"
push "$KONG_YML"

EMAIL_B="e2e-b-$(date +%s)@example.com"
curl -s -X POST "$PROXY/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"Passw0rd!23\"}" > "$TMP/reg-b.json"
curl -s -X POST "$PROXY/v1/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"Passw0rd!23\"}" > "$TMP/login-b.json"
APIKEY_B=$(python3 -c "import json;print(json.load(open('$TMP/reg-b.json'))['apiKey'])")
TOKEN_B=$(python3 -c "import json;print(json.load(open('$TMP/login-b.json'))['token'])")

# B se declara A. Las peticiones de A llevan también la identidad de A: con la
# pasarela sana es inocuo, porque se sobrescribe con el mismo valor, y permite
# que una ejecución contra una copia sin saneado llegue a la comparación que
# importa ---B viendo lo de A--- en lugar de quedarse en un 401 de fr.
AS_A=(-H "X-Account-Id: $ACCOUNT" -H "X-Auth-Channel: frontend" -H "X-Role: CUSTOMER")

curl -s -X POST "$PROXY$FR" -H "Authorization: Bearer $TOKEN" "${AS_A[@]}" \
  -H 'Content-Type: application/json' -d "{\"name\":\"saneado-$(date +%s)\"}" > "$TMP/gallery.json"
GALLERY=$(python3 -c "import json;print(json.load(open('$TMP/gallery.json')).get('id',''))" 2>/dev/null || true)
if [ -z "$GALLERY" ]; then
  echo "  ✗ fr real · A no pudo crear su galería: $(cat "$TMP/gallery.json")"
  FAILED=1
  GALLERY=sin-galeria
fi

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
total() { curl -s "$@" | python3 -c "import json,sys;print(json.load(sys.stdin).get('total','-'))" 2>/dev/null || echo -; }
at_least_one() { case "$1" in ''|*[!0-9]*) echo "$1" ;; *) if [ "$1" -ge 1 ]; then echo '≥1'; else echo "$1"; fi ;; esac; }

# Cada 404 de B va con el 200 de A sobre la MISMA galería: sin el par, un 404
# no distingue el saneado de un identificador mal construido.
check "fr real · JWT: A ve su galería; B, declarándose A, no" \
  "200|404" \
  "$(code "$PROXY$FR/$GALLERY" -H "Authorization: Bearer $TOKEN" "${AS_A[@]}")|$(code "$PROXY$FR/$GALLERY" -H "Authorization: Bearer $TOKEN_B" "${AS_A[@]}")"

check "fr real · API KEY: A ve su galería; B, declarándose A, no" \
  "200|404" \
  "$(code "$PROXY$FR/$GALLERY" -H "X-API-Key: $APIKEY" "${AS_A[@]}")|$(code "$PROXY$FR/$GALLERY" -H "X-API-Key: $APIKEY_B" "${AS_A[@]}")"

TOTAL_A=$(total "$PROXY$FR" -H "Authorization: Bearer $TOKEN" "${AS_A[@]}")
TOTAL_B=$(total "$PROXY$FR" -H "Authorization: Bearer $TOKEN_B" "${AS_A[@]}")
check "fr real · listado: A tiene ≥ 1 galería; B, declarándose A, 0" \
  "≥1|0" \
  "$(at_least_one "$TOTAL_A")|$TOTAL_B"

check "fr real · sin credencial, declarándose A: 401" \
  "401" \
  "$(code "$PROXY$FR/$GALLERY" "${AS_A[@]}")"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "TODAS LAS COMPROBACIONES PASAN"
else
  echo "HAY COMPROBACIONES QUE FALLAN"
fi
exit "$FAILED"
