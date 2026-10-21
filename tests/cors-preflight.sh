#!/usr/bin/env bash
#
# Preflight CORS sobre las cinco rutas de la pasarela.
#
# Un preflight nunca lleva credenciales: si el plugin de autenticación se
# ejecutara antes que el de CORS, respondería 401 y ningún navegador podría
# llamar a la API, aunque desde la terminal todo pareciera correcto. El canal
# web ES el navegador, así que este fallo no se ve desde curl salvo que se
# busque a propósito.
#
# Se comprueban las cinco rutas, no solo las autenticadas: el panel usa
# /v1/auth, y el orden de los plugins puede cambiar por ruta.
#
#   ./tests/cors-preflight.sh
#
# Requiere la pasarela levantada. No modifica la configuración.
set -uo pipefail

PROXY=${PROXY:-http://localhost:8000}
ORIGIN=${ORIGIN:-http://localhost:3001}
FAILED=0

ROUTES=(
  /v1/auth/login
  /v1/auth/validate-key
  /v1/pricing/webhooks/stripe
  /v1/pricing/checkout/create-session
  /v1/fr/commercial/verification
)

# Rutas autenticadas: sobre ellas se comprueba qué credencial puede enviar el
# navegador. La de fr es la que usa el panel para la inferencia.
AUTHENTICATED=(
  /v1/pricing/checkout/create-session
  /v1/fr/commercial/verification
)

# preflight <ruta> <cabeceras-solicitadas> → "<código>|<allow-origin>|<allow-headers>"
preflight() {
  local out
  out=$(curl -s -D - -o /dev/null -X OPTIONS "$PROXY$1" \
    -H "Origin: $ORIGIN" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: $2")
  local code allow_origin allow_headers
  code=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  allow_origin=$(printf '%s' "$out" | grep -i '^access-control-allow-origin:' | cut -d: -f2- | tr -d ' \r')
  allow_headers=$(printf '%s' "$out" | grep -i '^access-control-allow-headers:' | cut -d: -f2- | tr -d ' \r')
  printf '%s|%s|%s' "${code:-000}" "${allow_origin:-AUSENTE}" "${allow_headers:-AUSENTE}"
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

echo "→ preflight sin credenciales sobre las cinco rutas"
for route in "${ROUTES[@]}"; do
  result=$(preflight "$route" "authorization,content-type")
  code=${result%%|*}
  rest=${result#*|}
  origin=${rest%%|*}

  # 401 aquí significaría que space-auth (PRIORITY 1000) se ejecuta antes que
  # cors (PRIORITY 2000) y se está comiendo el preflight. 404, que la ruta no
  # acepta OPTIONS.
  check "$route responde 200 con Access-Control-Allow-Origin" \
    "200|$ORIGIN" "$code|$origin"
done

echo "→ el navegador puede enviar Authorization (canal web)"
for route in "${AUTHENTICATED[@]}"; do
  result=$(preflight "$route" "authorization,content-type")
  allowed=${result##*|}
  case ",$(printf '%s' "$allowed" | tr 'A-Z' 'a-z')," in
    *,authorization,*) echo "  ✓ $route: Authorization está en Access-Control-Allow-Headers" ;;
    *) echo "  ✗ $route: Authorization NO está en Access-Control-Allow-Headers: $allowed"; FAILED=1 ;;
  esac
done

echo "→ el navegador NO puede enviar X-API-Key (decisión deliberada, docs#69)"
# El canal de API es máquina a máquina: una API KEY en el navegador es una API
# KEY en el código del cliente. Se fija con un test para que revertirlo sea una
# decisión y no un descuido: el preflight responde 200, pero sin la cabecera en
# la lista, de modo que el navegador bloquea la petición real. El preflight la
# pide expresamente, como haría un navegador que fuera a enviarla.
for route in "${AUTHENTICATED[@]}"; do
  result=$(preflight "$route" "x-api-key,content-type")
  allowed=${result##*|}
  case ",$(printf '%s' "$allowed" | tr 'A-Z' 'a-z')," in
    *,x-api-key,*) echo "  ✗ $route: X-API-Key aparece en Access-Control-Allow-Headers"; FAILED=1 ;;
    *) echo "  ✓ $route: X-API-Key no está en Access-Control-Allow-Headers" ;;
  esac
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "TODAS LAS COMPROBACIONES PASAN"
else
  echo "HAY COMPROBACIONES QUE FALLAN"
fi
exit "$FAILED"
