#!/usr/bin/env bash
# Live smoke checks for an already deployed OpenCloud + Euro-Office stack.
# This does not create/edit a document; use the browser E2E checklist for that.
set -Eeuo pipefail
IFS=$'\n\t'

COMPOSE_DIR=""
OPENcloud_URL=""
EURO_OFFICE_URL=""
TIMEOUT=10

log() { printf '[opencloud-live] %s\n' "$*"; }
fail() { printf '[opencloud-live] FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Check a running OpenCloud + Euro-Office deployment.

Usage:
  bash tests/opencloud-live-smoke.sh \
    --compose-dir DIR \
    --opencloud-url https://cloud.example.com \
    --office-url https://office.example.com

Options:
  --compose-dir DIR       Upstream opencloud-compose checkout
  --opencloud-url URL     Public OpenCloud HTTPS URL
  --office-url URL        Public Euro-Office HTTPS URL
  --timeout SECONDS       Per-request timeout (default: 10)
  --help                  Show this help

Requires Docker Compose v2 and curl. Uses normal TLS verification; do not
disable certificate checks for a production deployment.
EOF
}
while (($#)); do
  case "$1" in
    --compose-dir) (($# >= 2)) || fail "--compose-dir needs a value"; COMPOSE_DIR="$2"; shift 2 ;;
    --opencloud-url) (($# >= 2)) || fail "--opencloud-url needs a value"; OPENcloud_URL="$2"; shift 2 ;;
    --office-url) (($# >= 2)) || fail "--office-url needs a value"; EURO_OFFICE_URL="$2"; shift 2 ;;
    --timeout) (($# >= 2)) || fail "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ -d "$COMPOSE_DIR" ]] || fail "Compose directory does not exist."
[[ "$OPENcloud_URL" =~ ^https://[^/]+/?$ ]] || fail "--opencloud-url must be an HTTPS origin."
[[ "$EURO_OFFICE_URL" =~ ^https://[^/]+/?$ ]] || fail "--office-url must be an HTTPS origin."
[[ "$OPENcloud_URL" != "$EURO_OFFICE_URL" ]] || fail "OpenCloud and Euro-Office URLs must differ."
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "--timeout must be a positive integer."
command -v docker >/dev/null 2>&1 || fail "Docker is required."
command -v curl >/dev/null 2>&1 || fail "curl is required."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required."

cd "$COMPOSE_DIR"
running="$(docker compose ps --services --filter status=running)"
for service in opencloud euro-office yjs; do
  grep -Fxq "$service" <<< "$running" || fail "Compose service '$service' is not running. Check: docker compose ps"
done
log "OpenCloud and Euro-Office containers are running."

request() {
  local url="$1" output="$2" status
  status="$(curl --silent --show-error --location --max-time "$TIMEOUT" \
    --output "$output" --write-out '%{http_code}' "$url")" ||
    fail "Request failed: $url"
  printf '%s' "$status"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

office_health="$(request "${EURO_OFFICE_URL%/}/healthcheck" "$tmp/health")"
[[ "$office_health" == 200 ]] || fail "Euro-Office /healthcheck returned HTTP $office_health (expected 200)."
health_body="$(tr -d '\r\n[:space:]' < "$tmp/health")"
[[ "$health_body" == true ]] || fail "Euro-Office healthcheck did not return true (got: $health_body)."
log "Euro-Office healthcheck passed."

discovery="$(request "${EURO_OFFICE_URL%/}/hosting/discovery" "$tmp/discovery")"
[[ "$discovery" == 200 ]] || fail "Euro-Office WOPI discovery returned HTTP $discovery (expected 200)."
grep -qi 'wopi-discovery' "$tmp/discovery" || fail "Euro-Office discovery response did not contain a WOPI discovery document."
log "Euro-Office discovery endpoint passed."

cloud_root="$(request "${OPENcloud_URL%/}/" "$tmp/cloud-root")"
case "$cloud_root" in
  200|301|302|303|307|308) ;;
  *) fail "OpenCloud root returned unexpected HTTP $cloud_root." ;;
esac
log "OpenCloud web endpoint responded (HTTP $cloud_root)."

# Both routes are explicitly provided by the upstream OpenCloud proxy.
# A successful route response or an auth/method response proves routing;
# a missing route or gateway/server error is treated as a failure.
for route in wopi collaboration; do
  status="$(request "${OPENcloud_URL%/}/$route" "$tmp/$route")"
  case "$status" in
    2??|3??|401|403|405) ;;
    *) fail "OpenCloud /$route route returned HTTP $status; expected a live route (2xx/3xx/401/403/405)." ;;
  esac
  log "OpenCloud /$route route responded (HTTP $status)."
done

log "Live service smoke checks passed."
log "This does not prove authenticated document editing or save/reopen persistence; complete the browser E2E checklist in docs/opencloud-integration.md."
