#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/configure-opencloud.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/compose/weboffice" "$TMP/compose/external-proxy"
touch "$TMP/compose/docker-compose.yml" "$TMP/compose/.env.example"
touch "$TMP/compose/weboffice/euro-office.yml"
touch "$TMP/compose/external-proxy/opencloud.yml" "$TMP/compose/external-proxy/euro-office.yml"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == compose && "$2" == version ]]; then
  echo "Docker Compose version v2.30.0"
  exit 0
fi
if [[ "$1" == compose && "$2" == config && "$3" == --quiet ]]; then
  exit 0
fi
echo "Unexpected docker invocation: $*" >&2
exit 1
EOF
chmod +x "$TMP/bin/docker"
PATH="$TMP/bin:$PATH" bash "$SCRIPT" \
  --compose-dir "$TMP/compose" \
  --opencloud-domain cloud.example.test \
  --office-domain office.example.test
grep -Fxq 'COMPOSE_FILE=docker-compose.yml:weboffice/euro-office.yml:external-proxy/opencloud.yml:external-proxy/euro-office.yml' "$TMP/compose/.env"
grep -Fxq 'OC_DOMAIN=cloud.example.test' "$TMP/compose/.env"
grep -Fxq 'EURO_OFFICE_DOMAIN=office.example.test' "$TMP/compose/.env"
grep -Eq '^EURO_OFFICE_JWT_SECRET=[a-f0-9]{64}$' "$TMP/compose/.env"
grep -Eq '^INITIAL_ADMIN_PASSWORD=[a-f0-9]{48}$' "$TMP/compose/.env"
[[ "$(stat -c '%a' "$TMP/compose/.env")" == 600 ]]
echo "OpenCloud configuration test passed."
