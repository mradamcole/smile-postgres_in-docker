# SmileCDR + PostgreSQL (local Docker stack)

Utility scripts that find the newest SmileCDR Docker image tarball in your Downloads folder, load it into Docker, and start a **dev** stack with SmileCDR and the latest stable PostgreSQL. SmileCDR is configured to use PostgreSQL instead of the default embedded H2 database.

This is for local development and upgrade testing. It does not include NGINX or TLS.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine + Compose v2) running
- A SmileCDR Docker release archive from [releases.smilecdr.com](https://releases.smilecdr.com/), typically named:

  `smilecdr-YYYY.MM.RXX-docker.tar.gz`

  Place it in your user Downloads folder (`~/Downloads` on macOS, `%USERPROFILE%\Downloads` on Windows).

## Quick start

### Windows (PowerShell)

```powershell
cd c:\github\smile-postgres_in-docker
.\scripts\smile-postgres-up.ps1
```

### macOS / Linux / Git Bash

```bash
cd /path/to/smile-postgres_in-docker
chmod +x scripts/smile-postgres-up.sh
./scripts/smile-postgres-up.sh
```

Both scripts:

1. Pick the highest SmileCDR version under Downloads (by `YYYY.MM.RNN`, not file date)
2. Resolve a recent stable Postgres major from Docker Hub (fallback: `17`), using `postgres:{major}-alpine`
3. Generate files under `.runtime/smilecdr-<version>/`
4. Load the image if needed, patch `cdr-config-Master.properties` for Postgres, and `docker compose up -d --build`

When SmileCDR finishes starting, logs should include `Smile, we're up and running! :)`.

| Endpoint | Default URL |
|----------|-------------|
| Web Admin Console | http://localhost:9100 (`admin` / `password`) |
| FHIRWeb | http://localhost:8001 |
| FHIR API | http://localhost:8000 |
| JSON Admin API | http://localhost:9000 |
| Postgres (host) | `localhost:5432` (db/user `cdr` / password from `.env`) |

## Configure ports and credentials

On first run the script copies [`.env.example`](.env.example) to:

`.runtime/smilecdr-<version>/.env`

Edit that file (or `.env.example` before the first run), then run the script again so compose and SmileCDR properties are regenerated.

| Variable | Default | Purpose |
|----------|---------|---------|
| `FHIR_PORT` | 8000 | FHIR endpoint |
| `FHIRWEB_PORT` | 8001 | FHIRWeb console |
| `ADMIN_JSON_PORT` | 9000 | JSON Admin API |
| `ADMIN_WEB_PORT` | 9100 | Web Admin Console |
| `SMART_AUTH_PORT` | 9200 | SMART auth |
| `SMART_DEMO_PORT` | 9201 | SMART demo host |
| `POSTGRES_HOST_PORT` | 5432 | Host port for Postgres |
| `POSTGRES_MAJOR` | 17 | Fallback major if Hub lookup fails |
| `DB_CDR_NAME` / `DB_CDR_USER` / `DB_CDR_PASSWORD` | `cdr` / `cdr` / `SmileCDR` | Application DB |
| `SMILECDR_PLATFORM` | `linux/amd64` | Compose `platform` for Releases-site images |

Credentials in `.env.example` are for local development only.

## Script options

**PowerShell**

```powershell
.\scripts\smile-postgres-up.ps1 -DownloadsDir "D:\installers"
.\scripts\smile-postgres-up.ps1 -Tarball "C:\Users\you\Downloads\smilecdr-2026.08.R02-docker.tar.gz"
.\scripts\smile-postgres-up.ps1 -DryRun
.\scripts\smile-postgres-up.ps1 -ForceLoad
.\scripts\smile-postgres-up.ps1 -Down
```

**Bash**

```bash
./scripts/smile-postgres-up.sh --downloads-dir /path/to/folder
./scripts/smile-postgres-up.sh --tarball ~/Downloads/smilecdr-2026.08.R02-docker.tar.gz
./scripts/smile-postgres-up.sh --dry-run
./scripts/smile-postgres-up.sh --force-load
./scripts/smile-postgres-up.sh --down
```

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

Generated runtime files under `.runtime/` are gitignored.

## ARM64 note

Images from the Smile Releases site are **AMD64**. The compose file sets `platform: linux/amd64` (overridable via `SMILECDR_PLATFORM`).

On Apple Silicon, Docker Desktop can run that image via emulation. For a native ARM64 image, pull from Smile’s registry instead of using a Downloads tarball:

```bash
docker login https://docker.smilecdr.com -u <username>
docker pull --platform linux/arm64 docker.smilecdr.com/smilecdr:<version>
```

Then retag or adjust the generated Dockerfile `FROM` / compose image and set `SMILECDR_PLATFORM=linux/arm64`. Automated ARM64 registry pulls are out of scope for these scripts.

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| `no SmileCDR tarball found` | File name must match `smilecdr-YYYY.MM.RXX-docker.tar.gz` (or legacy `*-image.tar.bz2`) |
| `Docker is not running` | Start Docker Desktop; confirm `docker info` works |
| SmileCDR exits / H2 errors | Confirm `.runtime/.../cdr-config-Master.properties` has `POSTGRES_9_4` and URL host `postgresdb` |
| Postgres never healthy | `docker logs postgres_cdr-<version>`; ensure host port `POSTGRES_HOST_PORT` is free |
| Port already allocated | Change ports in the runtime `.env` and re-run the up script (common if another SmileCDR stack is already bound to 8000/9100/…) |
| Postgres 18 volume errors about `/var/lib/postgresql/data` | This stack mounts `/var/lib/postgresql` (required for Postgres 18+). Run with `-Down` / `--down`, then `docker compose … down -v` if an old volume remains, and start again |

## Layout

```
docker/
  compose.template.yml   # Compose template (placeholders filled at runtime)
  Dockerfile.postgres
  Dockerfile.smilecdr
  init_postgresdb.sh     # Creates cdr role/DB + Postgres 15+ grants
scripts/
  smile-postgres-up.sh
  smile-postgres-up.ps1
.env.example
```

## Out of scope

- NGINX / TLS reverse proxy
- Automatic download from the Smile releases portal (login required)
- Production hardening
