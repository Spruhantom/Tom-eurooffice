#!/usr/bin/env bash
# End-to-end service integration check: Nextcloud connector <-> Euro-Office Docs.
set -Eeuo pipefail

DOCUMENTSERVER_IMAGE="${EURO_OFFICE_IMAGE:-ghcr.io/euro-office/documentserver:latest}"
NEXTCLOUD_IMAGE="${NEXTCLOUD_IMAGE:-nextcloud:stable-apache}"
RUN_ID="${GITHUB_RUN_ID:-$$}"
NETWORK="eurooffice-integration-${RUN_ID}"
DOCS_CONTAINER="eurooffice-docs-${RUN_ID}"
NEXTCLOUD_CONTAINER="eurooffice-nextcloud-${RUN_ID}"
JWT_SECRET="$(openssl rand -hex 32)"
NEXTCLOUD_ADMIN_USER="integration-admin"
NEXTCLOUD_ADMIN_PASSWORD="$(openssl rand -hex 20)"
NEXTCLOUD_PORT=""

cleanup() {
  docker logs --tail 100 "$NEXTCLOUD_CONTAINER" 2>/dev/null || true
  docker logs --tail 100 "$DOCS_CONTAINER" 2>/dev/null || true
  docker rm -f "$NEXTCLOUD_CONTAINER" "$DOCS_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

wait_for_nextcloud() {
  local attempt
  for attempt in $(seq 1 90); do
    if docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ status --output=json 2>/dev/null |
      grep -q '"installed":true'; then
      echo "Nextcloud is initialized."
      return 0
    fi
    sleep 5
  done
  fail "Nextcloud did not finish initialization within 7.5 minutes."
}

echo "Pulling integration test images."
docker pull "$DOCUMENTSERVER_IMAGE"
docker pull "$NEXTCLOUD_IMAGE"

docker network create "$NETWORK" >/dev/null

echo "Starting Euro-Office Document Server."
docker run -d --name "$DOCS_CONTAINER" --network "$NETWORK" \
  --network-alias documentserver --restart=no \
  -e JWT_ENABLED=true -e "JWT_SECRET=$JWT_SECRET" \
  "$DOCUMENTSERVER_IMAGE" >/dev/null

echo "Waiting for Document Server health endpoint."
for attempt in $(seq 1 60); do
  if docker exec "$DOCS_CONTAINER" curl --fail --silent http://127.0.0.1/healthcheck |
    grep -qi true; then
    echo "Document Server health check passed."
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    fail "Document Server did not become healthy."
  fi
  sleep 5
done

echo "Starting Nextcloud."
docker run -d --name "$NEXTCLOUD_CONTAINER" --network "$NETWORK" \
  --network-alias nextcloud -p 127.0.0.1::80 \
  -e "NEXTCLOUD_ADMIN_USER=$NEXTCLOUD_ADMIN_USER" \
  -e "NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD" \
  -e "NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud" \
  "$NEXTCLOUD_IMAGE" >/dev/null

NEXTCLOUD_PORT="$(docker port "$NEXTCLOUD_CONTAINER" 80/tcp |
  sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n1)"
[[ -n "$NEXTCLOUD_PORT" ]] || fail "Could not determine Nextcloud's published port."

wait_for_nextcloud

echo "Installing the official Euro-Office Nextcloud connector."
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ app:install eurooffice
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ app:enable eurooffice

echo "Configuring matching JWT and internal service URLs."
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ config:app:set eurooffice DocumentServerUrl \
  --value="http://127.0.0.1:$NEXTCLOUD_PORT/"
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ config:app:set eurooffice DocumentServerInternalUrl \
  --value="http://documentserver/"
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ config:app:set eurooffice StorageUrl \
  --value="http://nextcloud/"
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ config:app:set eurooffice jwt_secret \
  --value="$JWT_SECRET"

echo "Checking the Document Server API from the Nextcloud container."
docker exec "$NEXTCLOUD_CONTAINER" curl --fail --silent \
  http://documentserver/healthcheck | grep -qi true ||
  fail "Nextcloud cannot reach the Document Server health endpoint."

docker exec "$NEXTCLOUD_CONTAINER" curl --fail --silent \
  http://documentserver/web-apps/apps/api/documents/api.js >/dev/null ||
  fail "The Document Server editor API JavaScript is unavailable."

echo "Running the connector's native connection/conversion check."
docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ eurooffice:documentserver --check

echo "Nextcloud + Euro-Office integration test passed."
