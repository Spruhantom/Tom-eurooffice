#!/usr/bin/env bash
# Configure the upstream OpenCloud Compose project to use Euro-Office.
set -Eeuo pipefail
IFS=$'\n\t'

PROXY="external-proxy"
COMPOSE_DIR=""
OC_DOMAIN=""
OFFICE_DOMAIN=""
ACME_EMAIL=""
START=no

log() { printf '[opencloud-setup] %s\n' "$*"; }
die() { printf '[opencloud-setup] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Configure OpenCloud + Euro-Office using the upstream opencloud-compose project.

Usage:
  bash configure-opencloud.sh --compose-dir DIR --opencloud-domain HOST \
    --office-domain HOST [--proxy external-proxy|traefik] [--acme-email EMAIL] [--start]

Options:
  --compose-dir DIR       Existing clone of opencloud-eu/opencloud-compose
  --opencloud-domain HOST Public hostname for OpenCloud
  --office-domain HOST   Public hostname for Euro-Office
  --proxy MODE           external-proxy (default) or traefik
  --acme-email EMAIL     Required with traefik for Let's Encrypt
  --start                Start the stack after validating its Compose config
  --help                 Show this help

The script creates/updates .env, generates strong secrets when absent, and
selects the upstream Euro-Office Compose modules. It does not configure DNS
or an external reverse proxy, and does not expose services by itself.
EOF
}
valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
    [[ "$1" != *..* ]] && [[ "$1" != *.-* ]] && [[ "$1" != *-.*
  ]]
}
set_env() {
  local key="$1" value="$2" file="$3" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  if [[ -f "$file" ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { prefix=key "="; written=0 }
      index($0,prefix)==1 {
        if (!written) { print prefix value; written=1 }
        next
      }
      { print }
      END { if (!written) print prefix value }
    ' "$file" > "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
}
read_env() {
  local key="$1" file="$2" line
  line="$(grep -m1 -E "^\${key}=" "$file" 2>/dev/null || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

while (($#)); do
  case "$1" in
    --compose-dir) (($# >= 2)) || die "--compose-dir needs a value"; COMPOSE_DIR="$2"; shift 2 ;;
    --opencloud-domain) (($# >= 2)) || die "--opencloud-domain needs a value"; OC_DOMAIN="$2"; shift 2 ;;
    --office-domain) (($# >= 2)) || die "--office-domain needs a value"; OFFICE_DOMAIN="$2"; shift 2 ;;
    --proxy) (($# >= 2)) || die "--proxy needs a value"; PROXY="$2"; shift 2 ;;
    --acme-email) (($# >= 2)) || die "--acme-email needs a value"; ACME_EMAIL="$2"; shift 2 ;;
    --start) START=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ -n "$COMPOSE_DIR" ]] || die "--compose-dir is required."
[[ -d "$COMPOSE_DIR" ]] || die "Compose directory does not exist: $COMPOSE_DIR"
[[ -n "$OC_DOMAIN" ]] && valid_host "$OC_DOMAIN" || die "Provide a valid --opencloud-domain hostname."
[[ -n "$OFFICE_DOMAIN" ]] && valid_host "$OFFICE_DOMAIN" || die "Provide a valid --office-domain hostname."
[[ "$OC_DOMAIN" != "$OFFICE_DOMAIN" ]] || die "OpenCloud and Euro-Office must use different hostnames."
case "$PROXY" in
  external-proxy|traefik) ;;
  *) die "Unsupported proxy mode '$PROXY'. Choose external-proxy or traefik." ;;
esac
if [[ "$PROXY" == traefik ]]; then
  [[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
    die "--acme-email with a valid address is required for Traefik/Let's Encrypt."
fi

for required in docker-compose.yml weboffice/euro-office.yml "$PROXY/opencloud.yml" "$PROXY/euro-office.yml" .env.example; do
  [[ -f "$COMPOSE_DIR/$required" ]] || die "Missing upstream Compose file: $required. Clone/update https://github.com/opencloud-eu/opencloud-compose."
done
command -v docker >/dev/null 2>&1 || die "Docker is required."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose)."
command -v openssl >/dev/null 2>&1 || die "openssl is required to generate secrets."

cd "$COMPOSE_DIR"
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 0600 .env
  log "Created .env from upstream .env.example."
else
  chmod 0600 .env
fi

COMPOSE_FILES="docker-compose.yml:weboffice/euro-office.yml:$PROXY/opencloud.yml:$PROXY/euro-office.yml"
set_env COMPOSE_FILE "$COMPOSE_FILES" .env
set_env OC_DOMAIN "$OC_DOMAIN" .env
set_env EURO_OFFICE_DOMAIN "$OFFICE_DOMAIN" .env
set_env INSECURE false .env

jwt_secret="$(read_env EURO_OFFICE_JWT_SECRET .env)"
if [[ -z "$jwt_secret" || "$jwt_secret" == changeme ]]; then
  jwt_secret="$(openssl rand -hex 32)"
  set_env EURO_OFFICE_JWT_SECRET "$jwt_secret" .env
  log "Generated a new Euro-Office JWT secret."
fi
[[ "${#jwt_secret}" -ge 32 ]] || die "EURO_OFFICE_JWT_SECRET must be at least 32 characters."

admin_password="$(read_env INITIAL_ADMIN_PASSWORD .env)"
admin_generated=no
if [[ -z "$admin_password" ]]; then
  admin_password="$(openssl rand -hex 24)"
  set_env INITIAL_ADMIN_PASSWORD "$admin_password" .env
  admin_generated=yes
  log "Generated an initial OpenCloud admin password."
fi
if [[ "$PROXY" == traefik ]]; then
  set_env TRAEFIK_ACME_MAIL "$ACME_EMAIL" .env
  set_env TRAEFIK_SERVICES_TLS_CONFIG "tls.certresolver=letsencrypt" .env
fi

# Ensure Collabora is not selected alongside Euro-Office.
if grep -q 'weboffice/collabora.yml\|/collabora.yml' <<< "$COMPOSE_FILES"; then
  die "Collabora and Euro-Office cannot be enabled together."
fi

log "Validating upstream Compose configuration."
docker compose config --quiet || die "docker compose config failed; inspect the .env values and upstream Compose files."
log "OpenCloud + Euro-Office configuration is valid."
log "Compose profile: $COMPOSE_FILES"
log "OpenCloud: https://$OC_DOMAIN"
log "Euro-Office: https://$OFFICE_DOMAIN"
log "Environment file: $COMPOSE_DIR/.env (permissions 0600)"
if [[ "$admin_generated" == yes ]]; then
  printf '\nIMPORTANT: Initial OpenCloud admin password (save it now):\n%s\n\n' "$admin_password"
fi
printf 'JWT secret is stored in .env. Keep that file private and back it up securely.\n'
if [[ "$PROXY" == external-proxy ]]; then
  printf '\nConfigure your external HTTPS proxy for OpenCloud and Euro-Office.\n'
  printf 'Forward OpenCloud traffic, including /wopi and /collaboration, to port 9200.\n'
  printf 'Forward Euro-Office traffic to port 9900.\n'
fi
if [[ "$START" == yes ]]; then
  log "Starting OpenCloud and Euro-Office containers."
  docker compose up -d
  log "Compose startup requested. Check service health and logs before use."
else
  printf '\nTo start the stack:\n  cd %q && docker compose up -d\n' "$COMPOSE_DIR"
fi
