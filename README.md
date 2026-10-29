# SmileCDR + PostgreSQL (local Docker stack)

Utility scripts that find the newest SmileCDR release in your Downloads folder and start a **dev** stack with SmileCDR and PostgreSQL. SmileCDR is configured to use PostgreSQL instead of the default embedded H2 database.

On **Apple Silicon**, the bash script prefers the **application binary** (`smilecdr-YYYY.MM.RXX.tar.gz`) and builds a native **linux/arm64** image (no QEMU). On other hosts it uses the **Docker image tarball** (`…-docker.tar.gz`) from the Releases site.

This is for local development and upgrade testing. It does not include NGINX or TLS.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine + Compose v2) running
- A SmileCDR release from [releases.smilecdr.com](https://releases.smilecdr.com/), in your Downloads folder (`~/Downloads` on macOS):

  | File | Use |
  |------|-----|
  | `smilecdr-YYYY.MM.RXX.tar.gz` | Application binary (native ARM64 Docker build on Apple Silicon) |
  | `smilecdr-YYYY.MM.RXX-docker.tar.gz` | Pre-built Docker image (AMD64; emulated on Apple Silicon) |

  Place at least one matching your platform. If both exist at the same version on arm64 Mac, the bash script picks the **binary** tarball.

## Quick start

### Windows (PowerShell)

```powershell
cd c:\github\smile-postgres_in-docker
copy .env.example .env   # once; then set SMILE_LICENSE_KEY if needed
.\scripts\smile-postgres-up.ps1
```

### macOS / Linux / Git Bash

```bash
cd /path/to/smile-postgres_in-docker
cp -n .env.example .env   # once; then set SMILE_LICENSE_KEY if needed
chmod +x scripts/smile-postgres-up.sh
./scripts/smile-postgres-up.sh
```

If `.env` is missing, the up script creates it from `.env.example`.

Both scripts:

1. Pick the highest SmileCDR version under Downloads (by `YYYY.MM.RNN`, not file date)
2. Resolve a recent stable Postgres major from Docker Hub (fallback from `POSTGRES_MAJOR` in `config.env`), using `postgres:{major}-alpine`
3. Generate files under `.runtime/smilecdr-<version>/`
4. **Binary path (bash, Apple Silicon default):** extract the app tarball, patch config, build `smilecdr:<version>-arm64` from UBI9 + OpenJDK 21, then `docker compose up -d --build`
5. **Docker-image path:** load the Releases tarball if needed, patch config, wrap the loaded image, then `docker compose up -d --build`

When SmileCDR finishes starting, logs should include `Smile, we're up and running! :)`.

| Endpoint | Default URL (see `config.env` for offsets) |
|----------|-------------|
| Web Admin Console | http://localhost:19100 (`admin` / `password`) |
| FHIRWeb | http://localhost:18001 |
| FHIR API | http://localhost:18000 |
| JSON Admin API | http://localhost:19000 |
| Postgres (host) | `localhost:15432` (db/user from `config.env`) |

## Configuration vs secrets

| File | Committed? | Purpose |
|------|------------|---------|
| [`config.env`](config.env) | Yes | Ports, Postgres settings, DB names, platform |
| [`.env`](.env) (from [`.env.example`](.env.example)) | No | Secrets only |

Edit `config.env`, then re-run the up script so compose and SmileCDR properties regenerate. To change ports only (keep database volumes and skip tarball reload), use `--update-ports` / `-UpdatePorts` after editing `config.env`.

### `config.env` settings

| Variable | Default | Purpose |
|----------|---------|---------|
| `FHIR_PORT` | 8000 | FHIR endpoint |
| `FHIRWEB_PORT` | 8001 | FHIRWeb console |
| `ADMIN_JSON_PORT` | 9000 | JSON Admin API |
| `ADMIN_WEB_PORT` | 9100 | Web Admin Console |
| `SMART_AUTH_PORT` | 9200 | SMART auth |
| `SMART_DEMO_PORT` | 9201 | SMART demo host |
| `POSTGRES_HOST_PORT` | 5432 | Host port for Postgres |
| `POSTGRES_MAJOR` | 17 | Fallback major if Hub lookup fails. Smile recommends **16** for production-like dev; Hub may resolve **18**—set `POSTGRES_MAJOR=16` before the first init if you want that major |
| `DB_CDR_NAME` / `DB_CDR_USER` / `DB_CDR_PASSWORD` | `cdr` / `cdr` / `SmileCDR` | Application DB |
| `SMILECDR_PLATFORM` | `linux/amd64` in file | Overridden to **`linux/arm64`** when using the binary tarball (bash). Used for both Postgres and SmileCDR in compose |

### `.env` secrets

| Variable | Purpose |
|----------|---------|
| `SMILE_LICENSE_KEY` | SmileCDR License Manager JWT (`module.license.config.jwt_text`). Leave empty if you are not using premium modules that require a key. |

The stack injects `SMILE_LICENSE_KEY` into the SmileCDR container. The patched properties file reads it with Smile’s `#{env['SMILE_LICENSE_KEY']}` substitution.

## Script options

**PowerShell**

```powershell
.\scripts\smile-postgres-up.ps1 -DownloadsDir "D:\installers"
.\scripts\smile-postgres-up.ps1 -Tarball "C:\Users\you\Downloads\smilecdr-2026.08.R02-docker.tar.gz"
.\scripts\smile-postgres-up.ps1 -DryRun
.\scripts\smile-postgres-up.ps1 -ForceLoad
.\scripts\smile-postgres-up.ps1 -UpdatePorts
.\scripts\smile-postgres-up.ps1 -Down
```

**Bash**

```bash
./scripts/smile-postgres-up.sh --downloads-dir /path/to/folder
./scripts/smile-postgres-up.sh --tarball ~/Downloads/smilecdr-2026.08.R02.tar.gz
./scripts/smile-postgres-up.sh --tarball ~/Downloads/smilecdr-2026.08.R02-docker.tar.gz
./scripts/smile-postgres-up.sh --dry-run
./scripts/smile-postgres-up.sh --force-load
./scripts/smile-postgres-up.sh --update-ports
./scripts/smile-postgres-up.sh --down
```

`--force-load` applies only to **docker-image** tarballs. Binary installs always rebuild from the extracted tree.

`-UpdatePorts` / `--update-ports` patches the existing `.runtime/.../cdr-config-Master.properties`, regenerates `docker-compose.yml` from `config.env`, rebuilds the SmileCDR service image (ports are baked in at build time), and runs `docker compose up -d`. Named volumes (Postgres data, Lucene, etc.) are kept. Docker may replace containers when host publish mappings change; it cannot remap ports on a running container in place.

## Useful commands

```bash
# Follow SmileCDR logs (version from your tarball)
docker logs -f smilecdr-2026.08.R02

# List containers
docker ps

# Stop and remove the stack (keeps generated files under .runtime/)
./scripts/smile-postgres-up.sh --down
# or
.\scripts\smile-postgres-up.ps1 -Down
```

Generated runtime files under `.runtime/` are gitignored. Do not commit `.env`.

## ARM64 / Apple Silicon

**Default (bash):** place `smilecdr-<version>.tar.gz` in Downloads. The script builds a native image tagged **`smilecdr:<version>-arm64`** (UBI9 OpenJDK 21) and sets **`platform: linux/arm64`** on both SmileCDR and Postgres in compose.

After a successful build:

```bash
docker image inspect smilecdr:2026.08.R02-arm64 --format '{{.Os}}/{{.Architecture}}'
# expected: linux/arm64

docker compose -p smilecdr-2026-08-r02 logs -f smilecdr-2026.08.R02
```

**Docker-image tarball** (`*-docker.tar.gz`) remains **AMD64** only from the Releases site; compose uses `linux/amd64` and Docker may emulate on Apple Silicon.

**Registry alternative:** pull a pre-built ARM64 image (same Releases login):

```bash
docker login https://docker.smilecdr.com -u <username>
docker pull --platform linux/arm64 docker.smilecdr.com/smilecdr:<version>
```

Automated registry pulls are not wired into these scripts; use the binary tarball path or adjust the generated compose/Dockerfile manually.

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| `no SmileCDR tarball found` | File name must match `smilecdr-YYYY.MM.RXX.tar.gz` or `…-docker.tar.gz` (or legacy `*-image.tar.bz2`) |
| `Docker is not running` | Start Docker Desktop; confirm `docker info` works |
| SmileCDR exits / H2 errors | Confirm `.runtime/.../cdr-config-Master.properties` has `POSTGRES_9_4` and URL host `postgresdb` |
| Postgres never healthy | `docker logs postgres_cdr-<version>`; ensure host port `POSTGRES_HOST_PORT` is free |
| Port already allocated | The up script checks host ports from `config.env` before starting and exits with a warning listing busy ports (and Docker container names when known). Edit `config.env` and re-run. Ports already held by this stack’s own containers are allowed so refreshes still work. |
| Postgres 18 volume errors about `/var/lib/postgresql/data` | This stack mounts `/var/lib/postgresql` (required for Postgres 18+). Run with `-Down` / `--down`, then `docker compose … down -v` if an old volume remains, and start again |
| Premium module license errors | Set `SMILE_LICENSE_KEY` in `.env` and re-run (or restart) the stack |

## Layout

```
config.env               # Non-secret ports and DB settings (committed)
.env.example             # Template for secrets
.env                     # Secrets only (gitignored)
docker/
  compose.template.yml
  Dockerfile.postgres
  Dockerfile.smilecdr
  Dockerfile.smilecdr.binary
  init_postgresdb.sh
scripts/
  smile-postgres-up.sh
  smile-postgres-up.ps1
```

## Out of scope

- NGINX / TLS reverse proxy
- Automatic download from the Smile releases portal (login required)
- Production hardening
