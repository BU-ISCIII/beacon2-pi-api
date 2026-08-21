#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

# Servicio objetivo. Sin argumento => "all" (comportamiento original).
# El nombre debe coincidir con el servicio definido en podman compose.
SERVICE="${1:-all}"

if [[ "$#" -gt 1 ]]; then
    echo "Uso: $0 [all|db|idp-db|admin-ui|beaconprod|apache-beacon|template-ui]" >&2
    exit 2
fi

want() {
    [[ "${SERVICE}" == "all" || "${SERVICE}" == "$1" ]]
}

case "${SERVICE}" in
    all|db|idp-db|admin-ui|beaconprod|apache-beacon|template-ui)
        ;;
    *)
        echo "ERROR: servicio no soportado: ${SERVICE}" >&2
        echo "Uso: $0 [all|db|idp-db|admin-ui|beaconprod|apache-beacon|template-ui]" >&2
        exit 2
        ;;
esac

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

# Solo exigimos detener el contenedor o los contenedores del objetivo.
case "${SERVICE}" in
    all)
        target_containers=(
            "${BEACON_CONTAINER}"
            "${ADMIN_UI_CONTAINER}"
            "${KEYCLOAK_CONTAINER}"
            "${POSTGRES_CONTAINER}"
            "${MONGO_CONTAINER}"
            "${MONGO_EXPRESS_CONTAINER}"
            "${TEMPLATE_UI_CONTAINER}"
            "${APACHE_CONTAINER}"
        )
        ;;
    db)
        target_containers=("${MONGO_CONTAINER}")
        ;;
    idp-db)
        target_containers=("${POSTGRES_CONTAINER}")
        ;;
    admin-ui)
        target_containers=("${ADMIN_UI_CONTAINER}")
        ;;
    beaconprod)
        target_containers=("${BEACON_CONTAINER}")
        ;;
    apache-beacon)
        target_containers=("${APACHE_CONTAINER}")
        ;;
    template-ui)
        target_containers=("${TEMPLATE_UI_CONTAINER}")
        ;;
esac

running_containers=""

for container in "${target_containers[@]}"; do
    if podman ps --format '{{.Names}}' | grep -Fxq "${container}"; then
        running_containers+="${container}"$'\n'
    fi
done

if [[ -n "${running_containers}" ]]; then
    echo "ERROR: detén primero los contenedores:" >&2
    printf '%s' "${running_containers}" >&2
    exit 1
fi

MONGO_ROOT="${BIND_ROOT}/runtime/mongo"
POSTGRES_DATA="${BIND_ROOT}/runtime/postgres/data"
ADMIN_UI_DATA="${BIND_ROOT}/runtime/admin-ui"
CERTS_DIR="${BIND_ROOT}/etc/certs"

echo "Creando rutas necesarias (${SERVICE})..."

if want db; then
    mkdir -p \
        "${MONGO_ROOT}/db" \
        "${MONGO_ROOT}/configdb" \
        "${MONGO_ROOT}/caseLevelData" \
        "${APP_LOG_DIR}/mongo"

    podman unshare touch "${APP_LOG_DIR}/mongo/mongod.log"
fi

if want idp-db; then
    mkdir -p \
        "${POSTGRES_DATA}" \
        "${APP_LOG_DIR}/postgres"
fi

if want admin-ui; then
    mkdir -p "${ADMIN_UI_DATA}"
fi

if want beaconprod; then
    mkdir -p \
        "${CERTS_DIR}" \
        "${APP_LOG_DIR}"

    podman unshare touch "${APP_LOG_DIR}/beacon.log"
fi

if want apache-beacon; then
    mkdir -p "${APP_LOG_DIR}/apache"
fi

if want db; then
    echo "Ajustando MongoDB..."

    podman unshare chown -R \
        "${MONGO_UID}:${MONGO_GID}" \
        "${MONGO_ROOT}"

    podman unshare chmod 0700 \
        "${MONGO_ROOT}/db" \
        "${MONGO_ROOT}/configdb"
fi

if want idp-db; then
    echo "Ajustando PostgreSQL..."

    # El entrypoint debe arrancar como root del namespace.
    podman unshare chown -R 0:0 "${POSTGRES_DATA}"
    podman unshare chmod 0700 "${POSTGRES_DATA}"
fi

if want admin-ui; then
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
        "${APP_ROOT}/beacon/connections/mongo/conf.py"
        "${APP_ROOT}/beacon/auth/idp_providers"
        "${APP_ROOT}/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types"
    )

    for writable_path in "${admin_ui_writable_paths[@]}"; do
        if podman unshare test -e "${writable_path}"; then
            # Escritura sobre los ficheros existentes y acceso a directorios.
            podman unshare setfacl -R \
                -m "u:${ADMIN_UI_UID}:rwX" \
                "${writable_path}"

            # Los nuevos ficheros creados heredarán la ACL.
            if podman unshare test -d "${writable_path}"; then
                podman unshare find "${writable_path}" -type d -exec \
                    setfacl -m "d:u:${ADMIN_UI_UID}:rwX" {} +
            fi
        fi
    done
fi

echo "Ajustando logs..."

if want beaconprod; then
    podman unshare chown \
        "${BEACON_UID}:${BEACON_GID}" \
        "${APP_LOG_DIR}/beacon.log"

    podman unshare chmod 0644 \
        "${APP_LOG_DIR}/beacon.log"
fi

if want db; then
    podman unshare chown \
        "${MONGO_UID}:${MONGO_GID}" \
        "${APP_LOG_DIR}/mongo/mongod.log"

    podman unshare chmod 0644 \
        "${APP_LOG_DIR}/mongo/mongod.log"
fi

if want idp-db; then
    podman unshare chown -R \
        "${POSTGRES_UID}:${POSTGRES_GID}" \
        "${APP_LOG_DIR}/postgres"

    podman unshare chmod 0755 \
        "${APP_LOG_DIR}/postgres"
fi

if want apache-beacon; then
    podman unshare chown -R \
        "${APACHE_UID}:${APACHE_GID}" \
        "${APP_LOG_DIR}/apache"

    podman unshare chmod 0755 \
        "${APP_LOG_DIR}/apache"
fi

if want beaconprod; then
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
fi

echo "Ajustando etiquetas SELinux..."

if command -v getenforce >/dev/null 2>&1 &&
   [[ "$(getenforce)" != "Disabled" ]]; then

    if [[ "${SERVICE}" == "all" ]]; then
        selinux_paths=(
            "${APP_ROOT}/beacon"
            "${APP_ROOT}/adminui"
            "${APP_ROOT}/conf"
            "${APP_ROOT}/template-ui"
            "${BIND_ROOT}"
            "${APP_LOG_DIR}"
            "${APP_LOG_DIR}/apache"
        )
    else
        selinux_paths=()

        want db && selinux_paths+=(
            "${APP_ROOT}/beacon/connections/mongo"
            "${MONGO_ROOT}"
            "${APP_LOG_DIR}/mongo/mongod.log"
        )

        want idp-db && selinux_paths+=(
            "${POSTGRES_DATA}"
            "${APP_LOG_DIR}/postgres"
        )

        want admin-ui && selinux_paths+=(
            "${ADMIN_UI_DATA}"
            "${APP_ROOT}/adminui"
            "${APP_ROOT}/beacon"
        )

        want beaconprod && selinux_paths+=(
            "${APP_ROOT}/beacon"
            "${APP_LOG_DIR}/beacon.log"
            "${CERTS_DIR}"
        )

        want apache-beacon && selinux_paths+=(
            "${APP_ROOT}/conf"
            "${APP_LOG_DIR}/apache"
        )

        want template-ui && selinux_paths+=(
            "${APP_ROOT}/template-ui"
        )

        # Eliminar duplicados manteniendo el orden.
        mapfile -t selinux_paths < <(
            printf '%s\n' "${selinux_paths[@]}" |
                awk 'NF && !seen[$0]++'
        )
    fi

    selinux_existing=()

    for selinux_path in "${selinux_paths[@]}"; do
        if podman unshare test -e "${selinux_path}"; then
            selinux_existing+=("${selinux_path}")
        fi
    done

    if [[ "${#selinux_existing[@]}" -gt 0 ]]; then
        podman unshare chcon -R \
            -t container_file_t \
            -l s0 \
            "${selinux_existing[@]}"
    fi
fi

echo
echo "Estado final:"

if [[ "${SERVICE}" == "all" ]]; then
    status_paths=(
        "${MONGO_ROOT}/db"
        "${MONGO_ROOT}/configdb"
        "${POSTGRES_DATA}"
        "${ADMIN_UI_DATA}"
        "${ADMIN_UI_DATA}/db.sqlite3"
        "${APP_LOG_DIR}/beacon.log"
        "${APP_LOG_DIR}/mongo/mongod.log"
        "${APP_LOG_DIR}/postgres"
        "${APP_LOG_DIR}/apache"
        "${CERTS_DIR}/beacon_server.crt"
        "${CERTS_DIR}/beacon_server.key"
    )
else
    status_paths=()

    want db && status_paths+=(
        "${MONGO_ROOT}/db"
        "${MONGO_ROOT}/configdb"
        "${APP_LOG_DIR}/mongo/mongod.log"
    )

    want idp-db && status_paths+=(
        "${POSTGRES_DATA}"
        "${APP_LOG_DIR}/postgres"
    )

    want admin-ui && status_paths+=(
        "${ADMIN_UI_DATA}"
        "${ADMIN_UI_DATA}/db.sqlite3"
    )

    want beaconprod && status_paths+=(
        "${APP_LOG_DIR}/beacon.log"
        "${CERTS_DIR}/beacon_server.crt"
        "${CERTS_DIR}/beacon_server.key"
    )

    want apache-beacon && status_paths+=(
        "${APP_LOG_DIR}/apache"
    )

    want template-ui && status_paths+=(
        "${APP_ROOT}/template-ui"
    )
fi

for status_path in "${status_paths[@]}"; do
    if podman unshare test -e "${status_path}"; then
        podman unshare stat -c '%a %u:%g %n' "${status_path}"
    else
        echo "MISSING ${status_path}"
    fi
done

echo
echo "OK: permisos y etiquetas preparados (${SERVICE})."
