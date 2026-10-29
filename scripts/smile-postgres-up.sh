#!/usr/bin/env bash
# Find the newest SmileCDR Docker tarball in Downloads, load it, and start
# SmileCDR + PostgreSQL with Postgres as the default database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"

DOWNLOADS_DIR="${HOME}/Downloads"
TARBALL=""
DRY_RUN=0
DO_DOWN=0
FORCE_LOAD=0
PROJECT_HINT=""

usage() {
  cat <<'EOF'
Usage: smile-postgres-up.sh [options]

Options:
  --downloads-dir DIR   Folder to scan for SmileCDR tarballs (default: ~/Downloads)
  --tarball PATH        Use this tarball instead of discovering the newest one
  --dry-run             Print choices and paths; do not run docker
  --down                Stop and remove the compose stack for the chosen version
  --force-load          Always docker image load even if the tag already exists
  --project NAME        Compose project name override (default: smilecdr-<version>)
  -h, --help            Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --downloads-dir)
      [[ $# -ge 2 ]] || die "--downloads-dir requires a value"
      DOWNLOADS_DIR="$2"
      shift 2
      ;;
    --tarball)
      [[ $# -ge 2 ]] || die "--tarball requires a value"
      TARBALL="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --down)
      DO_DOWN=1
      shift
      ;;
    --force-load)
      FORCE_LOAD=1
      shift
      ;;
    --project)
      [[ $# -ge 2 ]] || die "--project requires a value"
      PROJECT_HINT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

# Parse SmileCDR version from a filename into YEAR MONTH RELEASE; print as sortable key.
version_key_from_name() {
  local name="$1"
  if [[ "$name" =~ smilecdr-([0-9]{4})\.([0-9]{2})\.R([0-9]+)-(docker\.tar\.gz|image\.tar\.bz2)$ ]]; then
    # 10# avoids bash printf treating 08/09 as invalid octal
    printf '%04d%02d%04d\n' \
      "$((10#${BASH_REMATCH[1]}))" \
      "$((10#${BASH_REMATCH[2]}))" \
      "$((10#${BASH_REMATCH[3]}))"
    return 0
  fi
  return 1
}

version_from_name() {
  local name="$1"
  if [[ "$name" =~ smilecdr-([0-9]{4}\.[0-9]{2}\.R[0-9]+)-(docker\.tar\.gz|image\.tar\.bz2)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

find_latest_tarball() {
  local dir="$1"
  [[ -d "$dir" ]] || die "downloads directory not found: $dir"

  local best_key="" best_path="" best_ver=""
  local f name key ver

  shopt -s nullglob
  for f in \
    "${dir}"/smilecdr-*-docker.tar.gz \
    "${dir}"/smilecdr-*-image.tar.bz2
  do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    key="$(version_key_from_name "$name")" || continue
    ver="$(version_from_name "$name")" || continue
    if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
      best_key="$key"
      best_path="$f"
      best_ver="$ver"
    fi
  done
  shopt -u nullglob

  [[ -n "$best_path" ]] || die "no SmileCDR tarball found in ${dir} (expected smilecdr-YYYY.MM.RXX-docker.tar.gz)"
  printf '%s\t%s\n' "$best_path" "$best_ver"
}

# Highest stable major with a published {major}-alpine tag on Docker Hub.
resolve_postgres_major() {
  local fallback="${1:-17}"
  local major

  if ! command -v curl >/dev/null 2>&1; then
    echo "$fallback"
    return 0
  fi

  # Probe descending majors; Hub "last_updated" pages miss older major tags.
  for major in 20 19 18 17 16 15 14; do
    if curl -fsSL --max-time 10 \
      "https://hub.docker.com/v2/repositories/library/postgres/tags/${major}-alpine" \
      >/dev/null 2>&1; then
      echo "$major"
      return 0
    fi
  done

  echo "$fallback"
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

load_env_file() {
  local file="$1"
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

set_prop() {
  # set_prop FILE KEY VALUE — update or append KEY = VALUE in properties file
  local file="$1" key="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    # Preserve spacing style roughly: key followed by spaces then =
    awk -v k="$key" -v v="$value" '
      BEGIN { done=0 }
      {
        line=$0
        if (match(line, /^[[:space:]]*[^=[:space:]]+[[:space:]]*=/)) {
          keypart=line
          sub(/[[:space:]]*=.*/, "", keypart)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", keypart)
          if (keypart == k) {
            # Keep original key token + padding before =
            prefix=line
            sub(/=.*/, "", prefix)
            print prefix "=" v
            done=1
            next
          }
        }
        print
      }
      END { if (!done) print k "=" v }
    ' "$file" >"$tmp"
  else
    cat "$file" >"$tmp"
    printf '\n%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
}

patch_smile_config() {
  local file="$1"
  local db_name="$2"
  local db_user="$3"
  local db_password="$4"
  local jdbc="jdbc:postgresql://postgresdb:5432/${db_name}"

  set_prop "$file" "module.clustermgr.config.db.driver" "POSTGRES_9_4"
  set_prop "$file" "module.persistence.config.db.driver" "POSTGRES_9_4"
  set_prop "$file" "module.clustermgr.config.db.url" "$jdbc"
  set_prop "$file" "module.persistence.config.db.url" "$jdbc"
  set_prop "$file" "module.clustermgr.config.db.username" "$db_user"
  set_prop "$file" "module.clustermgr.config.db.password" "$db_password"
  set_prop "$file" "module.persistence.config.db.username" "$db_user"
  set_prop "$file" "module.persistence.config.db.password" "$db_password"

  set_prop "$file" "module.fhir_endpoint.config.port" "${FHIR_PORT}"
  set_prop "$file" "module.fhirweb_endpoint.config.port" "${FHIRWEB_PORT}"
  set_prop "$file" "module.admin_json.config.port" "${ADMIN_JSON_PORT}"
  set_prop "$file" "module.admin_web.config.port" "${ADMIN_WEB_PORT}"
  set_prop "$file" "module.smart_auth.config.port" "${SMART_AUTH_PORT}"
  set_prop "$file" "module.smart_app_demo_host.config.port" "${SMART_DEMO_PORT}"

  # Keep FHIR base URL aligned with the FHIR port when the key exists.
  if grep -qE '^[[:space:]]*module\.fhir_endpoint\.config\.base_url\.fixed[[:space:]]*=' "$file"; then
    set_prop "$file" "module.fhir_endpoint.config.base_url.fixed" "http://localhost:${FHIR_PORT}"
  fi
}

extract_config_from_image() {
  local image="$1"
  local dest="$2"
  local cid
  cid="$(docker create "$image")" || die "failed to create temporary container from ${image}"
  if ! docker cp "${cid}:/home/smile/smilecdr/classes/cdr-config-Master.properties" "$dest"; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
    die "failed to extract cdr-config-Master.properties from ${image}"
  fi
  docker rm -f "$cid" >/dev/null
}

render_compose() {
  local template="$1"
  local out="$2"
  local version="$3"
  local postgres_tag="$4"
  local platform="$5"
  sed \
    -e "s/__SMILECDR_VERSION__/${version}/g" \
    -e "s/__POSTGRES_TAG__/${postgres_tag}/g" \
    -e "s/__SMILECDR_PLATFORM__/${platform}/g" \
    "$template" >"$out"
}

# --- Resolve tarball / version ---
if [[ -n "$TARBALL" ]]; then
  [[ -f "$TARBALL" ]] || die "tarball not found: $TARBALL"
  SMILE_VERSION="$(version_from_name "$(basename "$TARBALL")")" \
    || die "cannot parse SmileCDR version from filename: $(basename "$TARBALL")"
else
  IFS=$'\t' read -r TARBALL SMILE_VERSION < <(find_latest_tarball "$DOWNLOADS_DIR")
fi

RUNTIME_DIR="${REPO_ROOT}/.runtime/smilecdr-${SMILE_VERSION}"
COMPOSE_FILE="${RUNTIME_DIR}/docker-compose.yml"
# Compose project names: lowercase alphanumeric, hyphens, underscores only.
SAFE_VERSION="$(printf '%s' "${SMILE_VERSION//./-}" | tr '[:upper:]' '[:lower:]')"
PROJECT_NAME="${PROJECT_HINT:-smilecdr-${SAFE_VERSION}}"

# Seed env defaults
mkdir -p "$RUNTIME_DIR"
if [[ ! -f "${RUNTIME_DIR}/.env" ]]; then
  [[ -f "$ENV_EXAMPLE" ]] || die "missing ${ENV_EXAMPLE}"
  cp "$ENV_EXAMPLE" "${RUNTIME_DIR}/.env"
fi
load_env_file "${RUNTIME_DIR}/.env"

POSTGRES_MAJOR="${POSTGRES_MAJOR:-17}"
SMILECDR_PLATFORM="${SMILECDR_PLATFORM:-linux/amd64}"
FHIR_PORT="${FHIR_PORT:-8000}"
FHIRWEB_PORT="${FHIRWEB_PORT:-8001}"
ADMIN_JSON_PORT="${ADMIN_JSON_PORT:-9000}"
ADMIN_WEB_PORT="${ADMIN_WEB_PORT:-9100}"
SMART_AUTH_PORT="${SMART_AUTH_PORT:-9200}"
SMART_DEMO_PORT="${SMART_DEMO_PORT:-9201}"
POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-5432}"
DB_CDR_NAME="${DB_CDR_NAME:-cdr}"
DB_CDR_USER="${DB_CDR_USER:-cdr}"
DB_CDR_PASSWORD="${DB_CDR_PASSWORD:-SmileCDR}"
POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
POSTGRES_SUPERUSER_PASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-postgres}"

RESOLVED_MAJOR="$(resolve_postgres_major "$POSTGRES_MAJOR")"
POSTGRES_TAG="${RESOLVED_MAJOR}-alpine"
IMAGE_TAG="smilecdr:${SMILE_VERSION}"

echo "SmileCDR version:  ${SMILE_VERSION}"
echo "Tarball:           ${TARBALL}"
echo "Postgres image:    postgres:${POSTGRES_TAG}"
echo "Runtime dir:       ${RUNTIME_DIR}"
echo "Compose project:   ${PROJECT_NAME}"
echo "Platform:          ${SMILECDR_PLATFORM}"

if [[ "$DO_DOWN" -eq 1 ]]; then
  require_cmd docker
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    die "no generated compose file at ${COMPOSE_FILE}; run without --down first"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would run: docker compose -f ${COMPOSE_FILE} --project-name ${PROJECT_NAME} --env-file ${RUNTIME_DIR}/.env down"
    exit 0
  fi
  docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" --env-file "${RUNTIME_DIR}/.env" down
  echo "Stack stopped."
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would load image, patch config, build, and start the stack."
  exit 0
fi

require_cmd docker
docker info >/dev/null 2>&1 || die "Docker is not running (docker info failed)"

# Load image if needed
if [[ "$FORCE_LOAD" -eq 1 ]] || ! image_exists "$IMAGE_TAG"; then
  echo "Loading Docker image from tarball..."
  load_out="$(docker image load --input "$TARBALL")"
  echo "$load_out"
  if ! printf '%s' "$load_out" | grep -qiE "Loaded image:.*smilecdr:${SMILE_VERSION}|Loaded image ID:"; then
    # Some docker versions only print image ID; verify inspect
    image_exists "$IMAGE_TAG" || die "image ${IMAGE_TAG} not present after load"
  fi
else
  echo "Image ${IMAGE_TAG} already present (use --force-load to reload)."
fi

# Materialize build context
cp "${DOCKER_DIR}/init_postgresdb.sh" "${RUNTIME_DIR}/init_postgresdb.sh"
cp "${DOCKER_DIR}/Dockerfile.postgres" "${RUNTIME_DIR}/Dockerfile.postgres"
cp "${DOCKER_DIR}/Dockerfile.smilecdr" "${RUNTIME_DIR}/Dockerfile.smilecdr"
# Substitute ARG defaults in Dockerfiles for clarity (compose also passes build args)
sed -i.bak "s|ARG POSTGRES_TAG=.*|ARG POSTGRES_TAG=${POSTGRES_TAG}|" "${RUNTIME_DIR}/Dockerfile.postgres"
sed -i.bak "s|ARG SMILECDR_IMAGE=.*|ARG SMILECDR_IMAGE=${IMAGE_TAG}|" "${RUNTIME_DIR}/Dockerfile.smilecdr"
rm -f "${RUNTIME_DIR}/Dockerfile.postgres.bak" "${RUNTIME_DIR}/Dockerfile.smilecdr.bak"

CONFIG_PATH="${RUNTIME_DIR}/cdr-config-Master.properties"
echo "Extracting default cdr-config-Master.properties from ${IMAGE_TAG}..."
extract_config_from_image "$IMAGE_TAG" "$CONFIG_PATH"
patch_smile_config "$CONFIG_PATH" "$DB_CDR_NAME" "$DB_CDR_USER" "$DB_CDR_PASSWORD"

render_compose \
  "${DOCKER_DIR}/compose.template.yml" \
  "$COMPOSE_FILE" \
  "$SMILE_VERSION" \
  "$POSTGRES_TAG" \
  "$SMILECDR_PLATFORM"

echo "Starting stack..."
docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" --env-file "${RUNTIME_DIR}/.env" up -d --build

cat <<EOF

Stack is starting.

  Admin Web UI:  http://localhost:${ADMIN_WEB_PORT}  (default admin / password)
  FHIR endpoint: http://localhost:${FHIR_PORT}
  FHIRWeb:       http://localhost:${FHIRWEB_PORT}
  Postgres:      localhost:${POSTGRES_HOST_PORT}  (db/user ${DB_CDR_NAME}/${DB_CDR_USER})

Follow SmileCDR logs:
  docker logs -f smilecdr-${SMILE_VERSION}

Stop the stack:
  ${SCRIPT_DIR}/smile-postgres-up.sh --tarball '${TARBALL}' --down
EOF
