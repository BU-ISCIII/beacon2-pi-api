#!/usr/bin/env bash
# =============================================================
# Registra metadatos de datasets Beacon en MongoDB + configs API
# Pipeline Beacon AF - ISCIII
#
# Modos de uso:
#   1) Usar datasets.csv existente:
#      ./register_dataset_metadata.sh
#
#   2) Crear/sobrescribir datasets.csv con un dataset concreto:
#      ./register_dataset_metadata.sh <DATASET_ID> <DATASET_NAME>
#
# Ejemplo:
#   ./register_dataset_metadata.sh \
#     ISCIII_ES_WGSTRIO_3 \
#     "ISCIII Spanish WGS Trio 3 (PGx aggregated)"
#
# El script:
#   1. Detecta/crea datasets.csv
#   2. Convierte datasets.csv -> datasets.json con csv_to_bff.py
#   3. Importa datasets.json en MongoDB con TLS
#   4. Verifica que todos los datasets aparecen en db.datasets
#   5. Configura permisos en datasets_permissions.yml
#   6. Registra datasets en datasets_conf.yml
#   7. Ejecuta reindex una sola vez
#   8. Extrae filtering terms una sola vez
#   9. Reinicia beaconprod y espera 15 s
#  10. Verifica la API final
# =============================================================

set -euo pipefail

# -----------------------------
# Configuración
# -----------------------------
BEACON_DIR="/opt/beacon/beacon2-pi-api-isciii"
RI_TOOLS_DIR="${BEACON_DIR}/ri-tools"
DATASETS_CSV="${RI_TOOLS_DIR}/csv/datasets.csv"
DATASETS_JSON="${RI_TOOLS_DIR}/output_docs/datasets.json"
PERMISSIONS_YML="${BEACON_DIR}/beacon/permissions/datasets/datasets_permissions.yml"
DATASETS_CONF_YML="${BEACON_DIR}/beacon/conf/datasets/datasets_conf.yml"
API_BASE="http://beaconaf-isciiiciber.isciiides.es:8443/api"

LOG_DIR="/var/log/local/apps/beacon/ri-tools"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/register_datasets_${RUN_TS}.log"
METRICS_FILE="${LOG_DIR}/register_datasets_${RUN_TS}.metrics.tsv"
SUMMARY_FILE="${LOG_DIR}/register_dataset_summary.tsv"

MONGO_TLS_FLAGS=(
  --tls
  --tlsCertificateKeyFile /etc/mongo/certs/server.pem
  --tlsCAFile /etc/mongo/certs/ca.crt
  --tlsAllowInvalidCertificates
  -u root -p example
  --authenticationDatabase admin
)

MONGOIMPORT_URI="mongodb://root:example@127.0.0.1:27017/beacon?authSource=admin&tls=true&tlsCAFile=/etc/mongo/certs/ca.crt&tlsCertificateKeyFile=/etc/mongo/certs/server.pem"

SCRIPT_START_EPOCH="$(date +%s)"
CURRENT_STEP="initialization"
STEP_START_EPOCH="${SCRIPT_START_EPOCH}"
STATUS="RUNNING"
ERROR_MESSAGE=""
ACCESS_LEVEL="NA"
IS_SYNTHETIC="NA"
IS_TEST="NA"
DATASET_IDS=()
DATASET_NAMES=()
DATASET_COUNT="0"
API_DATASET_PRESENT="NA"

# -----------------------------
# Logging helpers
# -----------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

start_step() {
  CURRENT_STEP="$1"
  STEP_START_EPOCH="$(date +%s)"
  log "START_STEP: ${CURRENT_STEP}"
}

end_step() {
  local end_epoch duration
  end_epoch="$(date +%s)"
  duration=$(( end_epoch - STEP_START_EPOCH ))
  log "END_STEP: ${CURRENT_STEP} | duration_seconds=${duration}"
}

mongo_dataset_count() {
  local dataset_id="$1"
  podman exec mongoprod mongosh "${MONGO_TLS_FLAGS[@]}" beacon --quiet --eval \
    "print(db.datasets.countDocuments({id: '${dataset_id}'}))"
}

write_metrics() {
  local script_end_epoch total_duration dataset_ids_joined dataset_names_joined
  script_end_epoch="$(date +%s)"
  total_duration=$(( script_end_epoch - SCRIPT_START_EPOCH ))
  dataset_ids_joined="$(IFS=','; echo "${DATASET_IDS[*]:-NA}")"
  dataset_names_joined="$(IFS='|'; echo "${DATASET_NAMES[*]:-NA}")"

  cat > "${METRICS_FILE}" <<EOF
run_timestamp	dataset_count	dataset_ids	dataset_names	access_level	is_synthetic	is_test	api_dataset_present	status	total_duration_seconds	log_file	error_message
${RUN_TS}	${DATASET_COUNT}	${dataset_ids_joined}	${dataset_names_joined}	${ACCESS_LEVEL}	${IS_SYNTHETIC}	${IS_TEST}	${API_DATASET_PRESENT}	${STATUS}	${total_duration}	${LOG_FILE}	${ERROR_MESSAGE}
EOF

  if [ ! -f "${SUMMARY_FILE}" ]; then
    echo -e "run_timestamp	dataset_count	dataset_ids	dataset_names	access_level	is_synthetic	is_test	api_dataset_present	status	total_duration_seconds	log_file	error_message" > "${SUMMARY_FILE}"
  fi

  echo -e "${RUN_TS}	${DATASET_COUNT}	${dataset_ids_joined}	${dataset_names_joined}	${ACCESS_LEVEL}	${IS_SYNTHETIC}	${IS_TEST}	${API_DATASET_PRESENT}	${STATUS}	${total_duration}	${LOG_FILE}	${ERROR_MESSAGE}" >> "${SUMMARY_FILE}"
}

fail() {
  ERROR_MESSAGE="$1"
  STATUS="ERROR"
  log "ERROR: ${ERROR_MESSAGE}"
  write_metrics
  exit 1
}

on_exit() {
  local exit_code=$?
  if [ "${exit_code}" -ne 0 ] && [ "${STATUS}" = "RUNNING" ]; then
    STATUS="ERROR"
    ERROR_MESSAGE="Script interrupted or failed at step: ${CURRENT_STEP}"
    write_metrics || true
  fi
}
trap on_exit EXIT

choose_access_level() {
  echo "Nivel de acceso para los datasets registrados:"
  echo "  1) public"
  echo "  2) registered"
  echo "  3) controlled"
  read -r -p "Selecciona 1, 2 o 3 [1]: " choice
  choice="${choice:-1}"

  case "${choice}" in
    1) ACCESS_LEVEL="public" ;;
    2) ACCESS_LEVEL="registered" ;;
    3) ACCESS_LEVEL="controlled" ;;
    *) fail "Opción de acceso no válida: ${choice}" ;;
  esac
}

choose_dataset_conf_flags() {
  echo "¿Datasets sintéticos?"
  echo "  1) sí -> isSynthetic: true"
  echo "  2) no -> no se añade isSynthetic"
  read -r -p "Selecciona 1 o 2 [2]: " synth_choice
  synth_choice="${synth_choice:-2}"

  case "${synth_choice}" in
    1) IS_SYNTHETIC="true" ;;
    2) IS_SYNTHETIC="not_set" ;;
    *) fail "Opción isSynthetic no válida: ${synth_choice}" ;;
  esac

  echo "¿Datasets de test?"
  echo "  1) true"
  echo "  2) false"
  read -r -p "Selecciona 1 o 2 [2]: " test_choice
  test_choice="${test_choice:-2}"

  case "${test_choice}" in
    1) IS_TEST="true" ;;
    2) IS_TEST="false" ;;
    *) fail "Opción isTest no válida: ${test_choice}" ;;
  esac
}

load_datasets_from_csv() {
  DATASET_IDS=()
  DATASET_NAMES=()

  while IFS=',' read -r id name; do
    id="$(echo "${id}" | xargs)"
    name="$(echo "${name}" | xargs)"
    if [ "${id}" = "id" ] || [ -z "${id}" ]; then
      continue
    fi
    DATASET_IDS+=("${id}")
    DATASET_NAMES+=("${name}")
  done < "${DATASETS_CSV}"

  DATASET_COUNT="${#DATASET_IDS[@]}"

  if [ "${DATASET_COUNT}" -eq 0 ]; then
    fail "datasets.csv no contiene datasets válidos"
  fi
}

remove_yaml_block() {
  local path="$1"
  local dataset_id="$2"

  python3 - "${path}" "${dataset_id}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
dataset_id = sys.argv[2]

lines = path.read_text().splitlines()
out = []
skip = False

for line in lines:
    if line.startswith(dataset_id + ":"):
        skip = True
        continue
    if skip and line and not line.startswith((" ", "\t")):
        skip = False
    if not skip:
        out.append(line)

path.write_text("\n".join(out).rstrip() + "\n")
PY
}

append_permissions_block() {
  local dataset_id="$1"
  cat >> "${PERMISSIONS_YML}" <<EOF

${dataset_id}:
  ${ACCESS_LEVEL}:
    default_entry_types_granularity: record
EOF
}

append_datasets_conf_block() {
  local dataset_id="$1"
  {
    echo ""
    echo "${dataset_id}:"
    if [ "${IS_SYNTHETIC}" = "true" ]; then
      echo "  isSynthetic: true"
    fi
    echo "  isTest: ${IS_TEST}"
  } >> "${DATASETS_CONF_YML}"
}

# -----------------------------
# Preparación de logs
# -----------------------------
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

log "=========================================="
log "Beacon dataset metadata registration"
log "Run timestamp: ${RUN_TS}"
log "Log file: ${LOG_FILE}"
log "Metrics file: ${METRICS_FILE}"
log "Summary file: ${SUMMARY_FILE}"
log "=========================================="

# -----------------------------
# Paso 0: validaciones
# -----------------------------
start_step "validate_inputs"

for path in "${RI_TOOLS_DIR}" "$(dirname "${DATASETS_CSV}")" "$(dirname "${DATASETS_JSON}")" "$(dirname "${PERMISSIONS_YML}")" "$(dirname "${DATASETS_CONF_YML}")"; do
  if [ ! -d "${path}" ]; then
    fail "No existe el directorio requerido: ${path}"
  fi
done

if [ ! -f "${PERMISSIONS_YML}" ]; then
  fail "No existe datasets_permissions.yml: ${PERMISSIONS_YML}"
fi

if [ ! -f "${DATASETS_CONF_YML}" ]; then
  fail "No existe datasets_conf.yml: ${DATASETS_CONF_YML}"
fi

for cmd in podman curl jq python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    fail "${cmd} no está disponible en PATH"
  fi
done

log "Inputs OK"
end_step

# -----------------------------
# Paso 1: preparar datasets.csv
# -----------------------------
start_step "prepare_datasets_csv"

if [ "$#" -eq 2 ]; then
  DATASET_ID="$1"
  DATASET_NAME="$2"
  log "Modo argumentos: se sobrescribe datasets.csv con el dataset indicado"
  cat > "${DATASETS_CSV}" <<EOF
id,name
${DATASET_ID},${DATASET_NAME}
EOF
elif [ "$#" -eq 0 ]; then
  if [ -f "${DATASETS_CSV}" ]; then
    echo "Se ha detectado un datasets.csv preparado:"
    echo "----------------------------------------"
    cat "${DATASETS_CSV}"
    echo "----------------------------------------"
    read -r -p "¿Deseas registrar estos datasets? (y/N): " use_existing
    if [[ ! "${use_existing}" =~ ^[sSyY]$ ]]; then
      read -r -p "Dataset ID: " DATASET_ID
      read -r -p "Dataset name: " DATASET_NAME
      log "Sobrescribiendo datasets.csv con dataset manual: ${DATASET_ID}"
      cat > "${DATASETS_CSV}" <<EOF
id,name
${DATASET_ID},${DATASET_NAME}
EOF
    else
      log "Usando datasets.csv existente: ${DATASETS_CSV}"
    fi
  else
    read -r -p "Dataset ID: " DATASET_ID
    read -r -p "Dataset name: " DATASET_NAME
    log "Creando datasets.csv con dataset manual: ${DATASET_ID}"
    cat > "${DATASETS_CSV}" <<EOF
id,name
${DATASET_ID},${DATASET_NAME}
EOF
  fi
else
  fail "Uso: $0 [<DATASET_ID> <DATASET_NAME>]"
fi

load_datasets_from_csv

log "Datasets to register: ${DATASET_COUNT}"
cat "${DATASETS_CSV}" | tee -a "${LOG_FILE}"
end_step

# -----------------------------
# Paso 2: opciones interactivas
# -----------------------------
start_step "interactive_configuration"
choose_access_level
choose_dataset_conf_flags
log "Access level: ${ACCESS_LEVEL}"
log "isSynthetic: ${IS_SYNTHETIC}"
log "isTest: ${IS_TEST}"
end_step

# -----------------------------
# Paso 3: comprobar metadata existente
# -----------------------------
start_step "check_existing_dataset_metadata"
for dataset_id in "${DATASET_IDS[@]}"; do
  count="$(mongo_dataset_count "${dataset_id}")"
  log "MongoDB datasets before import for ${dataset_id}: ${count}"
  if [ "${count}" -gt 0 ]; then
    log "AVISO: ya existe ${count} registro(s) en db.datasets con id='${dataset_id}'."
    read -r -p "¿Borrar registros existentes para ${dataset_id} antes de importar? (s/N): " delete_ans
    if [[ "${delete_ans}" =~ ^[sSyY]$ ]]; then
      podman exec mongoprod mongosh "${MONGO_TLS_FLAGS[@]}" beacon --quiet --eval \
        "db.datasets.deleteMany({id: '${dataset_id}'})" | tee -a "${LOG_FILE}"
    else
      fail "Cancelado para evitar duplicados en db.datasets: ${dataset_id}"
    fi
  fi
done
end_step

# -----------------------------
# Paso 4: convertir CSV -> BFF JSON
# -----------------------------
start_step "csv_to_bff"
set +e
podman exec ri-tools python csv_to_bff.py \
  -e datasets \
  -i '/usr/src/app/csv/datasets.csv' \
  -o './output_docs/' 2>&1 | tee -a "${LOG_FILE}"
CSV_TO_BFF_EXIT_CODE="${PIPESTATUS[0]}"
set -e

if [ "${CSV_TO_BFF_EXIT_CODE}" -ne 0 ]; then
  fail "csv_to_bff.py terminó con exit code ${CSV_TO_BFF_EXIT_CODE}"
fi

if [ ! -f "${DATASETS_JSON}" ]; then
  fail "No se generó datasets.json: ${DATASETS_JSON}"
fi

log "datasets.json generated: ${DATASETS_JSON}"
end_step

# -----------------------------
# Paso 5: importar datasets.json a MongoDB
# -----------------------------
start_step "mongoimport_datasets"
podman cp "${DATASETS_JSON}" mongoprod:/tmp/datasets.json

set +e
MONGOIMPORT_OUTPUT="$(podman exec mongoprod mongoimport \
  --jsonArray \
  --uri "${MONGOIMPORT_URI}" \
  --tlsInsecure \
  --file /tmp/datasets.json \
  --collection datasets 2>&1)"
MONGOIMPORT_EXIT_CODE="$?"
set -e

echo "${MONGOIMPORT_OUTPUT}" | tee -a "${LOG_FILE}"

if [ "${MONGOIMPORT_EXIT_CODE}" -ne 0 ]; then
  fail "mongoimport terminó con exit code ${MONGOIMPORT_EXIT_CODE}"
fi

expected="${DATASET_COUNT} document(s) imported successfully. 0 document(s) failed to import."
if ! echo "${MONGOIMPORT_OUTPUT}" | grep -q "${expected}"; then
  fail "mongoimport no devolvió la salida esperada: ${expected}"
fi
end_step

# -----------------------------
# Paso 6: verificar MongoDB datasets
# -----------------------------
start_step "verify_mongodb_dataset_metadata"
for dataset_id in "${DATASET_IDS[@]}"; do
  count="$(mongo_dataset_count "${dataset_id}")"
  log "MongoDB datasets after import for ${dataset_id}: ${count}"
  if [ "${count}" -ne 1 ]; then
    fail "Esperado 1 registro en db.datasets para ${dataset_id}, encontrado ${count}"
  fi
done
end_step

# -----------------------------
# Paso 7: actualizar datasets_permissions.yml
# -----------------------------
start_step "update_datasets_permissions"
cp "${PERMISSIONS_YML}" "${PERMISSIONS_YML}.bak_${RUN_TS}"
for dataset_id in "${DATASET_IDS[@]}"; do
  remove_yaml_block "${PERMISSIONS_YML}" "${dataset_id}"
  append_permissions_block "${dataset_id}"
  grep -A 3 "^${dataset_id}:" "${PERMISSIONS_YML}" | tee -a "${LOG_FILE}"
done
end_step

# -----------------------------
# Paso 8: actualizar datasets_conf.yml
# -----------------------------
start_step "update_datasets_conf"
cp "${DATASETS_CONF_YML}" "${DATASETS_CONF_YML}.bak_${RUN_TS}"
for dataset_id in "${DATASET_IDS[@]}"; do
  remove_yaml_block "${DATASETS_CONF_YML}" "${dataset_id}"
  append_datasets_conf_block "${dataset_id}"
  grep -A 3 "^${dataset_id}:" "${DATASETS_CONF_YML}" | tee -a "${LOG_FILE}"
done
end_step

# -----------------------------
# Paso 9: reindex
# -----------------------------
start_step "mongo_reindex"
set +e
podman exec beaconprod python -m beacon.connections.mongo.reindex 2>&1 | tee -a "${LOG_FILE}"
REINDEX_EXIT_CODE="${PIPESTATUS[0]}"
set -e
if [ "${REINDEX_EXIT_CODE}" -ne 0 ]; then
  fail "reindex terminó con exit code ${REINDEX_EXIT_CODE}"
fi
end_step

# -----------------------------
# Paso 10: extract filtering terms
# -----------------------------
start_step "extract_filtering_terms"
FILTERING_RAW_LOG="${LOG_DIR}/extract_filtering_terms_${RUN_TS}.raw.log"
FILTERING_PROGRESS_LOG="${LOG_DIR}/extract_filtering_terms_${RUN_TS}.progress.log"

set +e
podman exec beaconprod python -m beacon.connections.mongo.extract_filtering_terms \
  > "${FILTERING_RAW_LOG}" 2>&1 &
PID=$!

waiting_message=(
  "Extracting filtering terms.  "
  "Extracting filtering terms.. "
  "Extracting filtering terms..."
)

index=0
while kill -0 "${PID}" 2>/dev/null; do
  printf "\r%s" "${waiting_message[$index]}"
  index=$(( (index + 1) % ${#waiting_message[@]} ))
  sleep 1
done

wait "${PID}"
FILTERING_EXIT_CODE="$?"
set -e

printf "\rExtracting filtering terms... done\n"

grep -E "^[[:space:]]*[0-9]+$|^[a-zA-Z_]+$|100%|[0-9]+%|genomicVariations|individuals|biosamples|runs|analyses|cohorts" \
  "${FILTERING_RAW_LOG}" > "${FILTERING_PROGRESS_LOG}" || true

log "extract_filtering_terms exit code: ${FILTERING_EXIT_CODE}"
log "extract_filtering_terms raw output: ${FILTERING_RAW_LOG}"
log "extract_filtering_terms raw output size: $(du -h "${FILTERING_RAW_LOG}" | cut -f1)"
log "extract_filtering_terms progress summary:"
cat "${FILTERING_PROGRESS_LOG}" | tee -a "${LOG_FILE}"

if [ "${FILTERING_EXIT_CODE}" -ne 0 ]; then
  fail "extract_filtering_terms terminó con exit code ${FILTERING_EXIT_CODE}"
fi
end_step

# -----------------------------
# Paso 11: reiniciar API
# -----------------------------
start_step "restart_beacon_api"
cd "${BEACON_DIR}"
podman-compose restart beaconprod 2>&1 | tee -a "${LOG_FILE}"
log "Sleeping 15 seconds to allow API startup"
sleep 15
end_step

# -----------------------------
# Paso 12: verificación final API
# -----------------------------
start_step "verify_api"
all_present=0
for dataset_id in "${DATASET_IDS[@]}"; do
  occurrences="$(curl -s "${API_BASE}/datasets?requestedGranularity=record&limit=1000" \
    | jq -r --arg id "${dataset_id}" '[.response.collections[]? | select(.id == $id)] | length')"
  log "API dataset occurrences for ${dataset_id}: ${occurrences}"
  if [ "${occurrences}" -ne 1 ]; then
    fail "La API debería devolver exactamente 1 entrada para ${dataset_id}, pero devuelve ${occurrences}"
  fi
  all_present=$((all_present + occurrences))
  curl -s "${API_BASE}/datasets?requestedGranularity=record&limit=1000" \
    | jq -r --arg id "${dataset_id}" '.response.collections[]? | select(.id == $id) | [.id, .name] | @tsv' \
    | tee -a "${LOG_FILE}"
done
API_DATASET_PRESENT="${all_present}"
end_step

# -----------------------------
# Paso 13: métricas finales
# -----------------------------
start_step "write_metrics"
STATUS="OK"
write_metrics
log "Metrics written: ${METRICS_FILE}"
log "Summary updated: ${SUMMARY_FILE}"
end_step

log "Finished with status: ${STATUS}"
exit 0
