#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: no existe ${ENV_FILE}" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required_variables=(
    APP_ROOT
    BIND_ROOT
    APP_LOG_DIR
    APACHE_LOG_DIR

    MONGO_UID MONGO_GID
    POSTGRES_UID POSTGRES_GID
    BEACON_UID BEACON_GID
    APACHE_UID APACHE_GID
    ADMIN_UI_UID ADMIN_UI_GID

    BEACON_CONTAINER
    ADMIN_UI_CONTAINER
    KEYCLOAK_CONTAINER
    POSTGRES_CONTAINER
    MONGO_CONTAINER
    MONGO_EXPRESS_CONTAINER
    TEMPLATE_UI_CONTAINER
    APACHE_CONTAINER
)

for variable in "${required_variables[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
        echo "ERROR: falta ${variable} en ${ENV_FILE}" >&2
        exit 1
    fi
done

running_containers="$(
    podman ps --format '{{.Names}}' |
    grep -E "^(${BEACON_CONTAINER}|${ADMIN_UI_CONTAINER}|${KEYCLOAK_CONTAINER}|${POSTGRES_CONTAINER}|${MONGO_CONTAINER}|${MONGO_EXPRESS_CONTAINER}|${TEMPLATE_UI_CONTAINER}|${APACHE_CONTAINER})$" \
    || true
)"

if [[ -n "${running_containers}" ]]; then
    echo "ERROR: detén primero los contenedores:" >&2
    echo "${running_containers}" >&2
    exit 1
fi

MONGO_ROOT="${BIND_ROOT}/runtime/mongo"
POSTGRES_DATA="${BIND_ROOT}/runtime/postgres/data"
ADMIN_UI_DATA="${BIND_ROOT}/runtime/admin-ui"
CERTS_DIR="${BIND_ROOT}/etc/certs"

echo "Creando rutas necesarias..."

mkdir -p \
    "${MONGO_ROOT}/db" \
    "${MONGO_ROOT}/configdb" \
    "${MONGO_ROOT}/caseLevelData" \
    "${POSTGRES_DATA}" \
    "${ADMIN_UI_DATA}" \
    "${CERTS_DIR}" \
    "${APP_LOG_DIR}/postgres" \
    "${APACHE_LOG_DIR}"

podman unshare touch \
    "${APP_LOG_DIR}/beacon.log" \
    "${APP_LOG_DIR}/mongod.log"

echo "Ajustando MongoDB..."

podman unshare chown -R \
    "${MONGO_UID}:${MONGO_GID}" \
    "${MONGO_ROOT}"

podman unshare chmod 0700 \
    "${MONGO_ROOT}/db" \
    "${MONGO_ROOT}/configdb"

echo "Ajustando PostgreSQL..."

# El entrypoint debe arrancar como root del namespace.
podman unshare chown -R 0:0 "${POSTGRES_DATA}"
podman unshare chmod 0700 "${POSTGRES_DATA}"

echo "Ajustando Admin UI..."

podman unshare chown -R \
    "${ADMIN_UI_UID}:${ADMIN_UI_GID}" \
    "${ADMIN_UI_DATA}"

podman unshare chmod 0700 "${ADMIN_UI_DATA}"

if podman unshare test -f "${ADMIN_UI_DATA}/db.sqlite3"; then
    podman unshare chmod 0600 \
        "${ADMIN_UI_DATA}/db.sqlite3"
fi

echo "Ajustando configuraciones editables desde Admin UI..."

if ! command -v setfacl >/dev/null 2>&1; then
    echo "ERROR: setfacl no está instalado." >&2
    exit 1
fi

admin_ui_writable_paths=(
    "${APP_ROOT}/beacon/conf/conf.py"
    "${APP_ROOT}/beacon/conf/datasets"
    "${APP_ROOT}/beacon/connections/mongo/conf.py"
    "${APP_ROOT}/beacon/permissions/datasets"
    "${APP_ROOT}/beacon/auth/idp_providers"
    "${APP_ROOT}/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types"
)

for writable_path in "${admin_ui_writable_paths[@]}"; do
    if podman unshare test -e "${writable_path}"; then
        # Escritura sobre los ficheros existentes y acceso a los directorios.
        podman unshare setfacl -R \
            -m "u:${ADMIN_UI_UID}:rwX" \
            "${writable_path}"

        # Los nuevos ficheros creados dentro de estos directorios heredarán la ACL.
        if podman unshare test -d "${writable_path}"; then
            podman unshare find "${writable_path}" -type d -exec \
                setfacl -m "d:u:${ADMIN_UI_UID}:rwX" {} +
        fi
    fi
done

echo "Ajustando logs..."

podman unshare chown \
    "${BEACON_UID}:${BEACON_GID}" \
    "${APP_LOG_DIR}/beacon.log"

podman unshare chmod 0644 \
    "${APP_LOG_DIR}/beacon.log"

podman unshare chown \
    "${MONGO_UID}:${MONGO_GID}" \
    "${APP_LOG_DIR}/mongod.log"

podman unshare chmod 0644 \
    "${APP_LOG_DIR}/mongod.log"

podman unshare chown -R \
    "${POSTGRES_UID}:${POSTGRES_GID}" \
    "${APP_LOG_DIR}/postgres"

podman unshare chown -R \
    "${APACHE_UID}:${APACHE_GID}" \
    "${APACHE_LOG_DIR}"

podman unshare chmod 0755 \
    "${APP_LOG_DIR}/postgres" \
    "${APACHE_LOG_DIR}"

echo "Ajustando certificados de Beacon..."

if podman unshare test -f "${CERTS_DIR}/beacon_server.crt"; then
    podman unshare chown \
        "${BEACON_UID}:${BEACON_GID}" \
        "${CERTS_DIR}/beacon_server.crt"

    podman unshare chmod 0644 \
        "${CERTS_DIR}/beacon_server.crt"
fi

if podman unshare test -f "${CERTS_DIR}/beacon_server.key"; then
    podman unshare chown \
        "${BEACON_UID}:${BEACON_GID}" \
        "${CERTS_DIR}/beacon_server.key"

    podman unshare chmod 0600 \
        "${CERTS_DIR}/beacon_server.key"
fi

echo "Ajustando etiquetas SELinux..."

if command -v getenforce >/dev/null 2>&1 &&
   [[ "$(getenforce)" != "Disabled" ]]; then

    podman unshare chcon -R \
        -t container_file_t \
        -l s0 \
        "${APP_ROOT}/beacon" \
        "${APP_ROOT}/adminui" \
        "${APP_ROOT}/conf" \
        "${APP_ROOT}/template-ui" \
        "${BIND_ROOT}" \
        "${APP_LOG_DIR}" \
        "${APACHE_LOG_DIR}"
fi

echo
echo "Estado final:"

status_paths=(
    "${MONGO_ROOT}/db"
    "${MONGO_ROOT}/configdb"
    "${POSTGRES_DATA}"
    "${ADMIN_UI_DATA}"
    "${ADMIN_UI_DATA}/db.sqlite3"
    "${APP_LOG_DIR}/beacon.log"
    "${APP_LOG_DIR}/mongod.log"
    "${APP_LOG_DIR}/postgres"
    "${APACHE_LOG_DIR}"
    "${CERTS_DIR}/beacon_server.crt"
    "${CERTS_DIR}/beacon_server.key"
)

for status_path in "${status_paths[@]}"; do
    if podman unshare test -e "${status_path}"; then
        podman unshare stat -c '%a %u:%g %n' "${status_path}"
    else
        echo "MISSING ${status_path}"
    fi
done

echo
echo "OK: permisos y etiquetas preparados."
