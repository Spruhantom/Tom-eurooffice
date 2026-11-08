#!/usr/bin/env bash
# Euro-Office Document Server installer for Arch/Omarchy, Debian/Ubuntu and Fedora.
set -Eeuo pipefail
IFS=$'\n\t'
IMAGE="${EURO_OFFICE_IMAGE:-ghcr.io/euro-office/documentserver:latest}"
CONTAINER="euro-office-documentserver"
CONFIG_DIR="/etc/euro-office"
DATA_DIR="/var/lib/euro-office"
ENV_FILE="${CONFIG_DIR}/server.env"
LOG_DIR="/var/log/euro-office"
LOG_FILE="${LOG_DIR}/installer.log"
DEFAULT_PORT=8080
log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run with sudo or as root."; }
have() { command -v "$1" >/dev/null 2>&1; }
init_log() { install -d -m 0750 "$LOG_DIR"; touch "$LOG_FILE"; chmod 0640 "$LOG_FILE"; }
detect_distro() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  . /etc/os-release
  case "${ID:-} ${ID_LIKE:-}" in
    *arch*) DISTRO=arch ;;
    *ubuntu*|*debian*) DISTRO=debian ;;
    *fedora*|*rhel*|*centos*) DISTRO=fedora ;;
    *) die "Unsupported distribution: ${PRETTY_NAME:-unknown}. Supported: Arch/Omarchy, Ubuntu, Debian, Fedora." ;;
  esac
  log "Detected ${PRETTY_NAME:-$DISTRO}."
}
install_docker() {
  if ! have docker; then
    log "Installing Docker from distribution repositories."
    case "$DISTRO" in
      arch) have pacman || die "pacman not found."; pacman -Syu --needed --noconfirm docker curl openssl ;;
      debian) have apt-get || die "apt-get not found."; export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y docker.io ca-certificates curl ;;
      fedora) have dnf || die "dnf not found."; dnf install -y moby-engine ;;
    esac
  fi
  case "$DISTRO" in
    arch)
      if ! have curl || ! have openssl; then
        pacman -Syu --needed --noconfirm curl openssl
      fi
      ;;
    debian) apt-get install -y curl ;;
    fedora) dnf install -y curl ;;
  esac
  have systemctl || die "systemd is required to manage Docker."
  systemctl enable --now docker || die "Could not start Docker. Check systemctl status docker."
  docker info >/dev/null 2>&1 || die "Docker daemon is unavailable."
}
check_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || die "Invalid TCP port: $1"
  if have ss && ss -ltnH "( sport = :$1 )" | grep -q .; then die "TCP port $1 is already in use."; fi
}
install_server() {
  local port="${1:-$DEFAULT_PORT}"
  require_root
  init_log
  detect_distro
  check_port "$port"
  install_docker
  if ! have openssl; then
    case "$DISTRO" in
      arch) pacman -Syu --needed --noconfirm openssl ;;
      debian) apt-get install -y openssl ;;
      fedora) dnf install -y openssl ;;
    esac
  fi
  install -d -m 0750 "$CONFIG_DIR"
  install -d -m 0750 "$DATA_DIR/documentserver" "$DATA_DIR/private" "$DATA_DIR/logs"
  local secret
  if [[ -s "$ENV_FILE" ]] && grep -q '^JWT_SECRET=' "$ENV_FILE"; then
    secret="$(sed -n 's/^JWT_SECRET=//p' "$ENV_FILE" | head -n1)"
    log "Keeping existing JWT secret."
  else
    secret="$(openssl rand -hex 32)"
    log "Generated a new JWT secret."
  fi
  umask 077
  printf 'JWT_SECRET=%s\nPORT=%s\nIMAGE=%s\n' "$secret" "$port" "$IMAGE" > "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  log "Pulling official community image: $IMAGE"
  docker pull "$IMAGE"
  if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    log "Replacing existing container; configuration and JWT secret are retained."
    docker rm -f "$CONTAINER" >/dev/null
  fi
  log "Starting Document Server on TCP port $port."
  local volume_suffix=""
  # SELinux hosts need private relabelling for writable bind mounts.
  [[ "$DISTRO" == fedora ]] && volume_suffix=":Z"
  docker run -d --name "$CONTAINER" --restart unless-stopped \
    --publish "127.0.0.1:$port:80" \
    --env JWT_ENABLED=true --env "JWT_SECRET=$secret" \
    --volume "$DATA_DIR/documentserver:/var/lib/euro-office/documentserver$volume_suffix" \
    --volume "$DATA_DIR/private:/var/www/euro-office/Data$volume_suffix" \
    --volume "$DATA_DIR/logs:/var/log/euro-office/documentserver$volume_suffix" \
    "$IMAGE" >/dev/null
  log "Waiting for HTTP health check."
  local i
  for i in $(seq 1 60); do
    if have curl && curl --fail --silent "http://127.0.0.1:$port/healthcheck" | grep -qi true; then
      log "Health check passed."
      printf '\nEuro-Office Document Server is running.\n'
      printf 'Local URL: http://127.0.0.1:%s\n' "$port"
      printf 'Container: %s\nJWT secret file: %s\nLog: %s\n' "$CONTAINER" "$ENV_FILE" "$LOG_FILE"
      printf '\nThe service is bound to localhost only. Put it behind an HTTPS reverse proxy before remote use.\n'
      printf 'Integrate it with a compatible platform such as Nextcloud; it is not standalone file storage.\n'
      printf 'Review upstream documentation and community-build support status before production use.\n'
      return 0
    fi
    if (( i == 60 )); then
      docker logs --tail 100 "$CONTAINER" 2>&1 | tee -a "$LOG_FILE" || true
      die "Health check failed after 60 attempts. Inspect docker logs $CONTAINER."
    fi
    sleep 5
  done
}
uninstall_server() {
  local purge="${1:-}"
  require_root
  init_log
  if have docker && docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    docker rm -f "$CONTAINER" >/dev/null
    log "Container removed."
  else
    log "Container is not present."
  fi
  if [[ "$purge" == yes ]]; then
    rm -rf -- "$CONFIG_DIR" "$DATA_DIR"
    log "Configuration, JWT secret and persistent server data removed."
  else
    log "Configuration and JWT secret retained at $ENV_FILE."
    log "Use --purge to delete them."
  fi
  log "Docker was left installed because other containers may depend on it."
}
usage() {
  cat <<EOF
Euro-Office Document Server installer
  sudo bash install.sh [--port 8080]
  sudo bash install.sh --uninstall [--purge]
  sudo bash install.sh --help
Options:
  --port PORT   Host TCP port (default 8080; service binds to localhost)
  --uninstall   Remove container but keep configuration
  --purge       With --uninstall, also delete config and JWT secret
  --help        Show this help
EOF
}
main() {
  local mode=install port=$DEFAULT_PORT purge=no
  while (($#)); do
    case "$1" in
      --uninstall) mode=uninstall; shift ;;
      --purge) purge=yes; shift ;;
      --port) (($# >= 2)) || die "--port requires a value"; port="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
  done
  if [[ "$mode" == uninstall ]]; then
    uninstall_server "$purge"
  else
    [[ "$purge" == no ]] || die "--purge requires --uninstall."
    install_server "$port"
  fi
}
main "$@"
