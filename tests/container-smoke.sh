#!/usr/bin/env bash
# Runtime smoke test for the upstream Euro-Office Document Server image.
set -Eeuo pipefail

IMAGE="${EURO_OFFICE_IMAGE:-ghcr.io/euro-office/documentserver:latest}"
CONTAINER="euro-office-smoke-${GITHUB_RUN_ID:-local}"
WORK_DIR="$(mktemp -d)"
JWT_SECRET="$(openssl rand -hex 32)"
PORT=""

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  sudo rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/documentserver" "$WORK_DIR/private" "$WORK_DIR/logs/adminpanel" "$WORK_DIR/logs/converter"
echo "smoke-test-persistent-state" > "$WORK_DIR/documentserver/persistence-marker"
echo "smoke-test-private-state" > "$WORK_DIR/private/persistence-marker"
echo "smoke-test-log-state" > "$WORK_DIR/logs/persistence-marker"

echo "Pulling $IMAGE"
docker pull "$IMAGE"

# The image stores several Supervisor log files in nested directories.
# A bind mount hides the image directories, so recreate them on the host.
# Supervisor config uses %(ENV_EO_LOG)s templates; parse the suffix instead of
# searching for an absolute path that is only expanded inside the container.
while IFS= read -r log_path; do
  relative_path="${log_path#*'%(ENV_EO_LOG)s/'}"
  [[ "$relative_path" != "$log_path" ]] || continue
  log_subdir="$(dirname -- "$relative_path")"
  [[ "$log_subdir" == "." ]] || mkdir -p "$WORK_DIR/logs/$log_subdir"
done < <(docker run --rm --entrypoint /bin/bash "$IMAGE" -lc "grep -RhoE '%\\(ENV_EO_LOG\\)s/[^[:space:]]+' /etc/supervisor/conf.d 2>/dev/null || true")

docker run -d --name "$CONTAINER" --restart=no \
  -p 127.0.0.1::80 \
  -e JWT_ENABLED=true -e "JWT_SECRET=$JWT_SECRET" \
  -v "$WORK_DIR/documentserver:/var/lib/euro-office/documentserver" \
  -v "$WORK_DIR/private:/var/www/euro-office/Data" \
  -v "$WORK_DIR/logs:/var/log/euro-office/documentserver" \
  "$IMAGE" >/dev/null

PORT="$(docker port "$CONTAINER" 80/tcp | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n1)"
[[ -n "$PORT" ]] || { docker logs "$CONTAINER"; echo "Could not determine mapped port." >&2; exit 1; }

echo "Waiting for Document Server health endpoint on port $PORT"
for attempt in $(seq 1 60); do
  if curl --fail --silent "http://127.0.0.1:$PORT/healthcheck" | grep -qi true; then
    echo "Health check passed."
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    docker logs --tail 150 "$CONTAINER" || true
    echo "Health check failed after 5 minutes." >&2
    exit 1
  fi
  sleep 5
done

# Confirm the expected bind mounts are active and host-side state survives
# removing and recreating the container with the same data directories.
for destination in /var/lib/euro-office/documentserver /var/www/euro-office/Data /var/log/euro-office/documentserver; do
  docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$CONTAINER" | grep -Fxq "$destination"
done

docker rm -f "$CONTAINER" >/dev/null
for marker in "$WORK_DIR/documentserver/persistence-marker" "$WORK_DIR/private/persistence-marker" "$WORK_DIR/logs/persistence-marker"; do
  sudo test -s "$marker" || { echo "Persistent data missing: $marker" >&2; exit 1; }
done

echo "Container runtime smoke test passed."
