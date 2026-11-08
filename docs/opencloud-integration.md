# OpenCloud + Euro-Office integration

Tom's Euro-Office Installer can configure the community Euro-Office integration
provided by the upstream [OpenCloud Compose project](https://github.com/opencloud-eu/opencloud-compose).

> **Support status:** OpenCloud documents this Euro-Office setup as community
> documentation, not an officially supported OpenCloud integration. Euro-Office
> is early-stage and may have stability issues. Review upstream support status
> before production use.

## What this configures

- OpenCloud's built-in collaboration/WOPI service and Euro-Office app provider,
  using the upstream Compose modules.
- A dedicated Euro-Office hostname and OpenCloud hostname.
- A strong 256-bit Euro-Office JWT secret if one is not already configured.
- A generated initial OpenCloud admin password if one is not already configured.
- Either the upstream Traefik profile or the external-proxy profile.
- A private `.env` file with mode 0600.

It does **not** implement a new WOPI server or replace OpenCloud's collaboration
service. It configures the upstream integration.

## 1. Get the upstream Compose project

Install Docker Engine and Docker Compose v2 first. The upstream project warns
that Compose v1 is not supported.

```bash
git clone https://github.com/opencloud-eu/opencloud-compose.git
```

## 2. Configure the integration

From a checkout of this repository, run:

```bash
bash scripts/configure-opencloud.sh \
  --compose-dir /path/to/opencloud-compose \
  --opencloud-domain cloud.example.com \
  --office-domain office.example.com \
  --proxy external-proxy
```

For the upstream Traefik deployment with Let's Encrypt:

```bash
bash scripts/configure-opencloud.sh \
  --compose-dir /path/to/opencloud-compose \
  --opencloud-domain cloud.example.com \
  --office-domain office.example.com \
  --proxy traefik \
  --acme-email admin@example.com
```

The script creates or updates the upstream `.env`, selects the Yjs collaboration
relay plus the Euro-Office/WOPI Compose modules, and validates the resulting
Compose configuration. Yjs enables real-time co-editing between users. It does not
start containers unless `--start` is supplied.

Save the generated initial admin password displayed by the script. The JWT
secret remains in the protected `.env` file. Back up that file securely.

## 3. Start the stack

```bash
cd /path/to/opencloud-compose
docker compose up -d
docker compose ps
docker compose logs --tail=100 opencloud euro-office
```

The exact service/container names may change with upstream Compose revisions;
use `docker compose config --services` if a log target differs.

## 4. Proxy and DNS requirements

For the external-proxy profile, configure valid HTTPS certificates and DNS for
both hostnames. Forward:

- OpenCloud hostname to the upstream OpenCloud service on port 9200, including
  the `/wopi` and `/collaboration` routes.
- Euro-Office hostname to the document server on port 9900.

The upstream external-proxy Compose files bind these ports to localhost by
default. Keep them private behind the proxy. If the proxy is on another host,
review the upstream exposed-port variant and firewall restrictions before
changing the bind address.

For Traefik, the script selects the upstream Traefik modules and configures
the ACME email. Ensure both DNS records point to the server and inbound ports
80/443 are reachable.

## Important compatibility notes

- Do not enable Collabora at the same time: both office backends use the same
  OpenCloud collaboration/WOPI service and are mutually exclusive.
- The OpenCloud collaboration service is served on the OpenCloud hostname;
  there is no separate WOPI hostname in the current upstream Compose design.
- Euro-Office and OpenCloud must be able to reach each other over the Compose
  network. Browser access to both HTTPS hostnames is also required.
- The initial admin password is used by the built-in LDAP setup on first
  initialization. Existing deployments keep their existing password.
- The integration remains community-supported and should be treated as
  experimental until real browser-based editing and persistence tests pass.

## 4. Validate a running deployment

After the stack is started and both public HTTPS hostnames resolve, run the
live smoke test from this repository:

```bash
bash tests/opencloud-live-smoke.sh \
  --compose-dir /path/to/opencloud-compose \
  --opencloud-url https://cloud.example.com \
  --office-url https://office.example.com
```

The script checks that the OpenCloud and Euro-Office Compose services are
running, Euro-Office returns `true` from `/healthcheck`, its
`/hosting/discovery` endpoint returns a WOPI discovery document, the
OpenCloud web endpoint responds, and the `/wopi` and `/collaboration` routes
do not return missing-route or gateway/server errors.

It uses normal TLS certificate verification. Fix DNS, certificates, reverse
proxy routing or container health issues rather than disabling TLS checks.

## 5. Browser editing and persistence acceptance test

The live smoke test proves service reachability, not that a user can edit and
save a file. Complete this test in a browser before calling the integration
production-ready:

1. Sign in to OpenCloud with a normal test user (not the administrator).
2. Create a new DOCX file in OpenCloud or upload a small test DOCX.
3. Open the file using the Euro-Office editor from the OpenCloud file menu.
4. Add a unique marker, for example `TomOS-E2E-2026-11-08-001`, and wait for
   the editor's save/synchronisation indicator to settle.
5. Close the editor, wait several seconds, then reopen the same file.
6. Confirm the marker is still present and the document is not reported as
   read-only or disconnected.
7. Download the file from OpenCloud and verify the marker is present in the
   downloaded DOCX as well.
8. Repeat with XLSX and PPTX if those formats are in the intended support
   scope. Test simultaneous editing in two browser sessions if co-editing is
   required.
9. Review OpenCloud and Euro-Office logs for WOPI, JWT, storage, or callback
   errors. Confirm the browser's network panel shows no failed WOPI or
   collaboration requests.

Record the date, OpenCloud/Euro-Office image versions, browser, test file
formats, and pass/fail outcome. Do not mark editing/persistence as passed
unless the close-and-reopen and downloaded-file checks both succeed.

## Automated checks

Run:

```bash
bash -n scripts/configure-opencloud.sh tests/opencloud-config.sh tests/opencloud-live-smoke.sh
bash tests/opencloud-config.sh
shellcheck --severity=warning scripts/configure-opencloud.sh tests/opencloud-config.sh tests/opencloud-live-smoke.sh
```

The configuration test uses a temporary Compose fixture and a Docker CLI stub;
it does not pull images or modify a real OpenCloud installation. The live smoke
test requires an already-running deployment and is not run in ordinary CI.

## Upstream references

- [OpenCloud Euro-Office community guide](https://docs-production.opencloud.eu/docs/next/admin/configuration/euro-office/)
- [OpenCloud Compose README](https://github.com/opencloud-eu/opencloud-compose)
- [OpenCloud collaboration/WOPI configuration](https://docs.opencloud.eu/de/docs/next/dev/server/services/collaboration/information/)
