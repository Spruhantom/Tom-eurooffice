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

The script creates or updates the upstream `.env`, sets the Euro-Office
Compose modules and validates the resulting Compose configuration. It does not
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

## Automated checks

Run:

```bash
bash -n scripts/configure-opencloud.sh tests/opencloud-config.sh
bash tests/opencloud-config.sh
shellcheck --severity=warning scripts/configure-opencloud.sh tests/opencloud-config.sh
```

The configuration test uses a temporary Compose fixture and a Docker CLI stub;
it does not pull images or modify a real OpenCloud installation.

## Upstream references

- [OpenCloud Euro-Office community guide](https://docs-production.opencloud.eu/docs/next/admin/configuration/euro-office/)
- [OpenCloud Compose README](https://github.com/opencloud-eu/opencloud-compose)
- [OpenCloud collaboration/WOPI configuration](https://docs.opencloud.eu/de/docs/next/dev/server/services/collaboration/information/)
