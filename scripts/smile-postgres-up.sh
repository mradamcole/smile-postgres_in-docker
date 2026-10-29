#!/usr/bin/env bash
# Find the newest SmileCDR tarball in Downloads (binary .tar.gz or docker image),
# build/start SmileCDR + PostgreSQL with Postgres as the default database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
CONFIG_FILE="${REPO_ROOT}/config.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"
SECRETS_FILE="${REPO_ROOT}/.env"

DOWNLOADS_DIR="${HOME}/Downloads"
TARBALL=""
DRY_RUN=0
DO_DOWN=0
FORCE_LOAD=0
UPDATE_PORTS=0
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
  --update-ports        Reapply config.env ports to a running stack (no tarball reload)
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
    --update-ports)
      UPDATE_PORTS=1
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
  if [[ "$name" =~ smilecdr-([0-9]{4})\.([0-9]{2})\.R([0-9]+)(\.tar\.gz|-(docker\.tar\.gz|image\.tar\.bz2))$ ]]; then
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
  if [[ "$name" =~ smilecdr-([0-9]{4}\.[0-9]{2}\.R[0-9]+)(\.tar\.gz|-(docker\.tar\.gz|image\.tar\.bz2))$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

install_mode_from_name() {
  local name="$1"
  if [[ "$name" =~ smilecdr-[0-9]{4}\.[0-9]{2}\.R[0-9]+\.tar\.gz$ ]]; then
    printf '%s\n' binary
  else
    printf '%s\n' docker-image
  fi
}

find_latest_tarball() {
  local dir="$1"
  [[ -d "$dir" ]] || die "downloads directory not found: $dir"

  local best_key="" best_path="" best_ver="" best_mode=""
  local prefer_binary=0
  local f name key ver mode host_arch

  host_arch="$(uname -m)"
  [[ "$host_arch" == "arm64" ]] && prefer_binary=1

  shopt -s nullglob
  for f in \
    "${dir}"/smilecdr-*.tar.gz \
    "${dir}"/smilecdr-*-image.tar.bz2
  do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    key="$(version_key_from_name "$name")" || continue
    ver="$(version_from_name "$name")" || continue
    mode="$(install_mode_from_name "$name")"
    if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
      best_key="$key"
      best_path="$f"
      best_ver="$ver"
      best_mode="$mode"
    elif [[ "$key" == "$best_key" ]]; then
      if [[ "$prefer_binary" -eq 1 && "$mode" == "binary" ]]; then
        best_path="$f"
        best_ver="$ver"
        best_mode="$mode"
      elif [[ "$prefer_binary" -eq 0 && "$mode" == "docker-image" ]]; then
        best_path="$f"
        best_ver="$ver"
        best_mode="$mode"
      fi
    fi
  done
  shopt -u nullglob

  [[ -n "$best_path" ]] || die "no SmileCDR tarball found in ${dir} (expected smilecdr-YYYY.MM.RXX.tar.gz or …-docker.tar.gz)"
  printf '%s\t%s\t%s\n' "$best_path" "$best_ver" "$best_mode"
}

resolve_runtime_install_mode() {
  if [[ -d "${RUNTIME_DIR}/smilecdr/bin" && -f "${RUNTIME_DIR}/smilecdr/bin/smilecdr" ]]; then
    printf '%s\n' binary
  else
    printf '%s\n' docker-image
  fi
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

  # License JWT from container env (SMILE_LICENSE_KEY in repo-root .env).
  set_prop "$file" "module.license.config.jwt_text" "#{env['SMILE_LICENSE_KEY']}"
}

# Compose env-file args: non-secret config.env, then secrets .env (overrides).
compose_env_file_args() {
  printf '%s\n' --env-file "$CONFIG_FILE"
  if [[ -f "$SECRETS_FILE" ]]; then
    printf '%s\n' --env-file "$SECRETS_FILE"
  fi
}

# Return container name if Docker has published this host port (incl. ranges like 8000-8002).
find_docker_port_holder() {
  local port="$1"
  local name ports
  command -v docker >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r name ports; do
    [[ -n "$name" && -n "$ports" ]] || continue
    # shellcheck disable=SC2001
    while IFS= read -r span; do
      [[ -n "$span" ]] || continue
      local start="${span%-*}"
      local end="${span#*-}"
      [[ "$end" =~ ^[0-9]+$ ]] || end="$start"
      if [[ "$port" -ge "$start" && "$port" -le "$end" ]]; then
        printf '%s\n' "$name"
        return 0
      fi
    done < <(printf '%s\n' "$ports" | grep -oE '(0\.0\.0\.0|127\.0\.0\.1|\[::\]):[0-9]+(-[0-9]+)?->' \
      | sed -E 's/.*:([0-9]+(-[0-9]+)?)->/\1/')
  done < <(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)
  return 0
}

# Secondary check for non-Docker listeners (skip broken Windows Store python stubs).
host_bind_blocked() {
  local port="$1"
  local py="" candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      if "$candidate" -c "import socket" >/dev/null 2>&1; then
        py="$(command -v "$candidate")"
        break
      fi
    fi
  done
  if [[ -n "$py" ]]; then
    "$py" - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
blocked = False
try:
    s.bind(("0.0.0.0", port))
except OSError:
    blocked = True
finally:
    s.close()
sys.exit(0 if blocked else 1)
PY
    return $?
  fi
  if (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

port_held_by_our_stack() {
  local holder="$1"
  [[ -n "$holder" ]] || return 1
  [[ "$holder" == "smilecdr-${SMILE_VERSION}" || "$holder" == "postgres_cdr-${SMILE_VERSION}" ]]
}

# Abort with a clear warning if config.env ports are taken by something else.
assert_host_ports_available() {
  local -a checks=(
    "FHIR_PORT:${FHIR_PORT}"
    "FHIRWEB_PORT:${FHIRWEB_PORT}"
    "ADMIN_JSON_PORT:${ADMIN_JSON_PORT}"
    "ADMIN_WEB_PORT:${ADMIN_WEB_PORT}"
    "SMART_AUTH_PORT:${SMART_AUTH_PORT}"
    "SMART_DEMO_PORT:${SMART_DEMO_PORT}"
    "POSTGRES_HOST_PORT:${POSTGRES_HOST_PORT}"
  )
  local -a busy=()
  local entry name port holder detail
  local seen_ports=" "

  for entry in "${checks[@]}"; do
    name="${entry%%:*}"
    port="${entry#*:}"
    case "$seen_ports" in
      *" $port "*) continue ;;
    esac
    seen_ports="${seen_ports}${port} "

    holder="$(find_docker_port_holder "$port")"
    if [[ -n "$holder" ]]; then
      if port_held_by_our_stack "$holder"; then
        continue
      fi
      busy+=("${name}=${port} (Docker container: ${holder})")
      continue
    fi

    if host_bind_blocked "$port"; then
      busy+=("${name}=${port} (in use on this host)")
    fi
  done

  if [[ ${#busy[@]} -eq 0 ]]; then
    return 0
  fi

  echo "warning: one or more host ports from config.env are already in use:" >&2
  for detail in "${busy[@]}"; do
    echo "  - ${detail}" >&2
  done
  echo "Edit ${CONFIG_FILE}, choose free ports, then re-run this script." >&2
  echo "Tip: ports already used by smilecdr-${SMILE_VERSION} / postgres_cdr-${SMILE_VERSION} are ignored (stack refresh)." >&2
  exit 1
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
  local install_mode="$6"
  local service_image build_args_file partial

  if [[ "$install_mode" == "binary" ]]; then
    service_image="smilecdr:${version}-arm64"
  else
    service_image="smilecdr_pg:${version}"
  fi

  build_args_file="$(mktemp)"
  if [[ "$install_mode" == "docker-image" ]]; then
    cat >"$build_args_file" <<EOF
      args:
        SMILECDR_IMAGE: smilecdr:${version}
EOF
  fi

  partial="$(mktemp)"
  sed \
    -e "s|__SMILECDR_VERSION__|${version}|g" \
    -e "s|__POSTGRES_TAG__|${postgres_tag}|g" \
    -e "s|__SMILECDR_PLATFORM__|${platform}|g" \
    -e "s|__SMILECDR_SERVICE_IMAGE__|${service_image}|g" \
    "$template" >"$partial"

  awk -v build_args_file="$build_args_file" '
    /__SMILECDR_BUILD_ARGS__/ {
      while ((getline line < build_args_file) > 0) {
        print line
      }
      close(build_args_file)
      next
    }
    { print }
  ' "$partial" >"$out"
  rm -f "$partial" "$build_args_file"
}

verify_smile_service_image() {
  local install_mode="$1"
  local inspect_tag arch
  if [[ "$install_mode" != "binary" ]]; then
    return 0
  fi
  inspect_tag="smilecdr:${SMILE_VERSION}-arm64"
  arch="$(docker image inspect "$inspect_tag" --format '{{.Os}}/{{.Architecture}}')"
  [[ "$arch" == "linux/arm64" ]] \
    || die "expected linux/arm64 for ${inspect_tag}, got ${arch:-unknown}"
  echo "SmileCDR image architecture: ${arch}"
}

materialize_postgres_build_context() {
  cp "${DOCKER_DIR}/init_postgresdb.sh" "${RUNTIME_DIR}/init_postgresdb.sh"
  cp "${DOCKER_DIR}/Dockerfile.postgres" "${RUNTIME_DIR}/Dockerfile.postgres"
  sed -i.bak "s|ARG POSTGRES_TAG=.*|ARG POSTGRES_TAG=${POSTGRES_TAG}|" "${RUNTIME_DIR}/Dockerfile.postgres"
  rm -f "${RUNTIME_DIR}/Dockerfile.postgres.bak"
}

materialize_binary_smile_context() {
  echo "Extracting application from binary tarball..."
  rm -rf "${RUNTIME_DIR}/smilecdr"
  tar -xzf "$TARBALL" -C "$RUNTIME_DIR"
  [[ -d "${RUNTIME_DIR}/smilecdr" ]] || die "expected smilecdr/ directory in ${TARBALL}"

  CONFIG_PATH="${RUNTIME_DIR}/cdr-config-Master.properties"
  cp "${RUNTIME_DIR}/smilecdr/classes/cdr-config-Master.properties" "$CONFIG_PATH"
  patch_smile_config "$CONFIG_PATH" "$DB_CDR_NAME" "$DB_CDR_USER" "$DB_CDR_PASSWORD"

  cp "${DOCKER_DIR}/Dockerfile.smilecdr.binary" "${RUNTIME_DIR}/Dockerfile.smilecdr"
}

materialize_docker_image_smile_context() {
  if [[ "$FORCE_LOAD" -eq 1 ]] || ! image_exists "$IMAGE_TAG"; then
    echo "Loading Docker image from tarball..."
    load_out="$(docker image load --input "$TARBALL")"
    echo "$load_out"
    if ! printf '%s' "$load_out" | grep -qiE "Loaded image:.*smilecdr:${SMILE_VERSION}|Loaded image ID:"; then
      image_exists "$IMAGE_TAG" || die "image ${IMAGE_TAG} not present after load"
    fi
  else
    echo "Image ${IMAGE_TAG} already present (use --force-load to reload)."
  fi

  cp "${DOCKER_DIR}/Dockerfile.smilecdr" "${RUNTIME_DIR}/Dockerfile.smilecdr"
  sed -i.bak "s|ARG SMILECDR_IMAGE=.*|ARG SMILECDR_IMAGE=${IMAGE_TAG}|" "${RUNTIME_DIR}/Dockerfile.smilecdr"
  rm -f "${RUNTIME_DIR}/Dockerfile.smilecdr.bak"

  CONFIG_PATH="${RUNTIME_DIR}/cdr-config-Master.properties"
  echo "Extracting default cdr-config-Master.properties from ${IMAGE_TAG}..."
  extract_config_from_image "$IMAGE_TAG" "$CONFIG_PATH"
  patch_smile_config "$CONFIG_PATH" "$DB_CDR_NAME" "$DB_CDR_USER" "$DB_CDR_PASSWORD"
}

# Read postgres_cdr:TAG from an existing generated compose file (update-ports mode).
postgres_tag_from_compose() {
  local compose_file="$1"
  local line tag
  line="$(grep -E '^[[:space:]]*image:[[:space:]]*postgres_cdr:' "$compose_file" | head -n1 || true)"
  [[ -n "$line" ]] || return 1
  tag="${line#*postgres_cdr:}"
  tag="${tag%%[[:space:]]*}"
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "$tag"
}

apply_port_updates() {
  local config_path="$1"
  local compose_file="$2"
  local postgres_tag="$3"
  local install_mode
  install_mode="$(resolve_runtime_install_mode)"

  [[ -f "$config_path" ]] || die "missing ${config_path}; run without --update-ports first"
  [[ -f "$compose_file" ]] || die "missing ${compose_file}; run without --update-ports first"

  patch_smile_config "$config_path" "$DB_CDR_NAME" "$DB_CDR_USER" "$DB_CDR_PASSWORD"
  render_compose \
    "${DOCKER_DIR}/compose.template.yml" \
    "$compose_file" \
    "$SMILE_VERSION" \
    "$postgres_tag" \
    "$SMILECDR_PLATFORM" \
    "$install_mode"

  echo "Applying port changes (volumes unchanged; containers recreated only if publish mappings changed)..."
  docker compose -f "$compose_file" --project-name "$PROJECT_NAME" "${COMPOSE_ENV_ARGS[@]}" build smilecdr
  docker compose -f "$compose_file" --project-name "$PROJECT_NAME" "${COMPOSE_ENV_ARGS[@]}" up -d
  verify_smile_service_image "$install_mode"
}

# --- Resolve tarball / version ---
if [[ -n "$TARBALL" ]]; then
  [[ -f "$TARBALL" ]] || die "tarball not found: $TARBALL"
  SMILE_VERSION="$(version_from_name "$(basename "$TARBALL")")" \
    || die "cannot parse SmileCDR version from filename: $(basename "$TARBALL")"
  INSTALL_MODE="$(install_mode_from_name "$(basename "$TARBALL")")"
else
  IFS=$'\t' read -r TARBALL SMILE_VERSION INSTALL_MODE < <(find_latest_tarball "$DOWNLOADS_DIR")
fi

RUNTIME_DIR="${REPO_ROOT}/.runtime/smilecdr-${SMILE_VERSION}"
COMPOSE_FILE="${RUNTIME_DIR}/docker-compose.yml"
# Compose project names: lowercase alphanumeric, hyphens, underscores only.
SAFE_VERSION="$(printf '%s' "${SMILE_VERSION//./-}" | tr '[:upper:]' '[:lower:]')"
PROJECT_NAME="${PROJECT_HINT:-smilecdr-${SAFE_VERSION}}"

mkdir -p "$RUNTIME_DIR"

[[ -f "$CONFIG_FILE" ]] || die "missing ${CONFIG_FILE}"
if [[ ! -f "$SECRETS_FILE" ]]; then
  [[ -f "$ENV_EXAMPLE" ]] || die "missing ${ENV_EXAMPLE}"
  cp "$ENV_EXAMPLE" "$SECRETS_FILE"
  echo "Created ${SECRETS_FILE} from .env.example — set SMILE_LICENSE_KEY if you need premium modules."
fi
# Non-secret settings first; .env secrets override on name collision.
load_env_file "$CONFIG_FILE"
load_env_file "$SECRETS_FILE"
COMPOSE_ENV_ARGS=()
while IFS= read -r line; do
  COMPOSE_ENV_ARGS+=("$line")
done < <(compose_env_file_args)

POSTGRES_MAJOR="${POSTGRES_MAJOR:-17}"
SMILECDR_PLATFORM="${SMILECDR_PLATFORM:-linux/amd64}"
if [[ "$INSTALL_MODE" == "binary" ]]; then
  SMILECDR_PLATFORM="linux/arm64"
fi
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
echo "Install mode:      ${INSTALL_MODE}"
echo "Tarball:           ${TARBALL}"
echo "Postgres image:    postgres:${POSTGRES_TAG}"
echo "Runtime dir:       ${RUNTIME_DIR}"
echo "Compose project:   ${PROJECT_NAME}"
echo "Platform:          ${SMILECDR_PLATFORM}"
if [[ "$INSTALL_MODE" == "binary" ]]; then
  echo "SmileCDR image:    smilecdr:${SMILE_VERSION}-arm64"
else
  echo "SmileCDR image:    smilecdr_pg:${SMILE_VERSION}"
fi

if [[ "$DO_DOWN" -ne 1 ]]; then
  assert_host_ports_available
fi

if [[ "$UPDATE_PORTS" -eq 1 && "$DO_DOWN" -eq 1 ]]; then
  die "use either --update-ports or --down, not both"
fi

if [[ "$UPDATE_PORTS" -eq 1 && "$FORCE_LOAD" -eq 1 ]]; then
  die "use either --update-ports or --force-load, not both"
fi

if [[ "$FORCE_LOAD" -eq 1 && "$INSTALL_MODE" == "binary" ]]; then
  die "--force-load applies to docker-image tarballs only"
fi

if [[ "$DO_DOWN" -eq 1 ]]; then
  require_cmd docker
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    die "no generated compose file at ${COMPOSE_FILE}; run without --down first"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would run: docker compose -f ${COMPOSE_FILE} --project-name ${PROJECT_NAME} ${COMPOSE_ENV_ARGS[*]} down"
    exit 0
  fi
  docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" "${COMPOSE_ENV_ARGS[@]}" down
  echo "Stack stopped."
  exit 0
fi

if [[ "$UPDATE_PORTS" -eq 1 ]]; then
  CONFIG_PATH="${RUNTIME_DIR}/cdr-config-Master.properties"
  POSTGRES_TAG="$(postgres_tag_from_compose "$COMPOSE_FILE")" \
    || die "cannot read Postgres tag from ${COMPOSE_FILE}; run a full up first"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would patch ${CONFIG_PATH}, regenerate compose, build smilecdr, and docker compose up -d"
    exit 0
  fi
  require_cmd docker
  docker info >/dev/null 2>&1 || die "Docker is not running (docker info failed)"
  apply_port_updates "$CONFIG_PATH" "$COMPOSE_FILE" "$POSTGRES_TAG"
  cat <<EOF

Port settings from config.env are applied.

  Admin Web UI:  http://localhost:${ADMIN_WEB_PORT}
  FHIR endpoint: http://localhost:${FHIR_PORT}
  FHIRWeb:       http://localhost:${FHIRWEB_PORT}
  Postgres:      localhost:${POSTGRES_HOST_PORT}

Follow SmileCDR logs:
  docker logs -f smilecdr-${SMILE_VERSION}
EOF
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$INSTALL_MODE" == "binary" ]]; then
    echo "[dry-run] would extract binary tarball, build smilecdr:${SMILE_VERSION}-arm64, and start the stack."
  else
    echo "[dry-run] would load docker image, patch config, build, and start the stack."
  fi
  exit 0
fi

require_cmd docker
docker info >/dev/null 2>&1 || die "Docker is not running (docker info failed)"

materialize_postgres_build_context
if [[ "$INSTALL_MODE" == "binary" ]]; then
  materialize_binary_smile_context
else
  materialize_docker_image_smile_context
fi

render_compose \
  "${DOCKER_DIR}/compose.template.yml" \
  "$COMPOSE_FILE" \
  "$SMILE_VERSION" \
  "$POSTGRES_TAG" \
  "$SMILECDR_PLATFORM" \
  "$INSTALL_MODE"

echo "Starting stack..."
docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT_NAME" "${COMPOSE_ENV_ARGS[@]}" up -d --build
verify_smile_service_image "$INSTALL_MODE"

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
