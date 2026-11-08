# Tom's Euro-Office Installer

A Bash installer for the Euro-Office Document Server community container. Supports Arch Linux (including Omarchy), Ubuntu, Debian and Fedora.

> **Important:** Euro-Office Document Server is an integration component, not a standalone office/storage application. It needs a compatible platform such as Nextcloud to store and manage documents. The upstream project currently describes its community container as intended for testing and integration. Review upstream documentation and support status before production use.

## Install

The installer detects the distribution, installs Docker from its distribution package if missing, enables Docker, pulls the official image, generates and stores a 256-bit JWT secret, starts the container and checks its health endpoint.

```bash
curl -fsSL https://raw.githubusercontent.com/Spruhantom/Tom-eurooffice/main/install.sh | sudo bash
```

Choose a different local port:

```bash
curl -fsSL https://raw.githubusercontent.com/Spruhantom/Tom-eurooffice/main/install.sh | sudo bash -s -- --port 8090
```

The service is deliberately published on **127.0.0.1** only. Configure a TLS reverse proxy before exposing it remotely. The installer does not configure DNS, TLS, firewall rules, Nextcloud, or a reverse proxy.

## Verify

```bash
docker ps --filter name=euro-office-documentserver
curl --fail http://127.0.0.1:8080/healthcheck
docker logs --tail 100 euro-office-documentserver
```

The health endpoint should return `true`. Use your selected port if it differs from 8080.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Or use the helper:

```bash
sudo bash uninstall.sh
```

To also delete the stored JWT secret, configuration and persistent server data:

```bash
sudo bash install.sh --uninstall --purge
```

Docker is intentionally left installed because other containers may depend on it.

## Paths and security

- Configuration and JWT secret: `/etc/euro-office/server.env` (root-only permissions)
- Persistent document-server state: `/var/lib/euro-office/documentserver`
- Runtime settings and generated keys: `/var/lib/euro-office/private`
- Document-server logs: `/var/lib/euro-office/logs`
- Installer log: `/var/log/euro-office/installer.log`
- Container: `euro-office-documentserver`
- Default local endpoint: `http://127.0.0.1:8080`

Keep the JWT secret confidential and configure the same secret in the integrating platform. Do not expose the container's HTTP port directly to the internet.

## Supported systems

- Arch Linux / Omarchy (pacman, Docker package)
- Ubuntu / Debian (apt, docker.io package)
- Fedora (dnf, moby-engine package)

Requires systemd and root privileges. Package availability depends on the enabled repositories.

## Image

Default: `ghcr.io/euro-office/documentserver:latest`

Override for a manual run with the `EURO_OFFICE_IMAGE` environment variable.

## Checks

```bash
bash -n install.sh uninstall.sh
```

GitHub Actions runs Bash syntax checks and ShellCheck on pushes and pull requests.

## Upstream

- [Euro-Office](https://github.com/Euro-Office)
- [DocumentServer](https://github.com/Euro-Office/DocumentServer)
- [Official documentation](https://euro-office.github.io/documentation/)

This is an independent community installer and is not affiliated with or endorsed by Euro-Office contributors.

## OpenCloud integration

This repository also provides a helper for configuring the community Euro-Office
integration with the upstream OpenCloud Compose project. It selects the
upstream Yjs, WOPI and app-provider Compose modules, generates strong secrets
and validates the Compose configuration. A live smoke test and a manual
browser edit/save/reopen acceptance checklist are also provided.

See [OpenCloud + Euro-Office integration](docs/opencloud-integration.md) for
setup instructions, proxy requirements and support-status warnings.

Quick configuration example:

```bash
git clone https://github.com/opencloud-eu/opencloud-compose.git
bash scripts/configure-opencloud.sh \
  --compose-dir ./opencloud-compose \
  --opencloud-domain cloud.example.com \
  --office-domain office.example.com \
  --proxy external-proxy
```

This helper configures the upstream deployment; it does not replace OpenCloud's
collaboration/WOPI service. Euro-Office and Collabora must not be enabled
together.
