#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} not found" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

BASE="${PUBLIC_SCHEME}://${PUBLIC_HOST}:${PUBLIC_PORT}"
API_BASE="${PUBLIC_SCHEME}://${API_PUBLIC_HOST}:${PUBLIC_PORT}"

# name|url|accepted status codes
checks=(
    "Template UI|${BASE}/|200"
    "Beacon API (main host)|${BASE}/api/info|200"
    "Beacon API (API host)|${API_BASE}/api/info|200"
    "Keycloak|${BASE}${KEYCLOAK_RELATIVE_PATH}/|200"
    "Admin UI|${BASE}/admin-ui/|200 302"
    "Mongo Express|${BASE}/mongo-express/|200 401"
)

failed=0

echo "Checking endpoints..."

for entry in "${checks[@]}"; do
    IFS='|' read -r name url expected <<< "${entry}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}" || echo "000")"
    if [[ " ${expected} " == *" ${code} "* ]]; then
        printf '  OK    %-24s HTTP %s\n' "${name}" "${code}"
    else
        printf '  FAIL  %-24s HTTP %s (expected: %s)\n' "${name}" "${code}" "${expected}"
        failed=1
    fi
done

echo

if [[ "${failed}" -eq 0 ]]; then
    echo "All endpoints responding."
else
    echo "Some endpoints failed. Check the logs:"
    echo "  make logs"
    exit 1
fi
