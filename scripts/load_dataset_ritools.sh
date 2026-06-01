#!/usr/bin/env bash
# =============================================================
# Carga un dataset en el Beacon vía ri-tools
# Pipeline Beacon AF - ISCIII
# =============================================================
# Uso:
#   ./load_dataset_ritools.sh <DATASET_ID> <VCF_PATH>
#
# Ejemplo:
#   ./load_dataset_ritools.sh ISCIII_ES_WGSTRIO_2 \
#     /impact_data/lega_data/beacon/inputs/ISCIII_ES_WGSTRIO_2.vcf.gz
#
# El script:
#   1. Verifica que el VCF existe
#   2. Edita conf.py con el datasetId proporcionado
#   3. Vacía files_to_read/ y copia el VCF
#   4. Ejecuta ri-tools y guarda log
#   5. Verifica en MongoDB cuántas variantes se insertaron
#   6. Avisa si hay discrepancia entre VCF y MongoDB
#   7. Guarda métricas por ejecución y resumen acumulado
# =============================================================

set -euo pipefail

# --- Argumentos ---
if [ "$#" -ne 2 ]; then
  echo "Uso: $0 <DATASET_ID> <VCF_PATH>"
  echo "Ejemplo: $0 ISCIII_ES_WGSTRIO_2 /impact_data/lega_data/beacon/inputs/ISCIII_ES_WGSTRIO_2.vcf.gz"
  exit 1
fi

DATASET_ID="$1"
VCF_PATH="$2"

# --- Configuración ---
BEACON_DIR="/opt/beacon/beacon2-pi-api-isciii"
CONF_PY="${BEACON_DIR}/ri-tools/conf/conf.py"
FILES_TO_READ="${BEACON_DIR}/ri-tools/files/vcf/files_to_read"

LOG_DIR="/var/log/local/apps/beacon/ri-tools"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
SAFE_DATASET_ID="$(echo "${DATASET_ID}" | sed 's|/|_|g')"
LOG_FILE="${LOG_DIR}/ri_tools_${SAFE_DATASET_ID}_${RUN_TS}.log"
METRICS_FILE="${LOG_DIR}/ri_tools_${SAFE_DATASET_ID}_${RUN_TS}.metrics.tsv"
SUMMARY_FILE="${LOG_DIR}/ri_tools_summary.tsv"

MONGO_TLS_FLAGS=(
  --tls
  --tlsCertificateKeyFile /etc/mongo/certs/server.pem
  --tlsCAFile /etc/mongo/certs/ca.crt
  --tlsAllowInvalidCertificates
  -u root -p example
  --authenticationDatabase admin
)

SCRIPT_START_EPOCH="$(date +%s)"
CURRENT_STEP="initialization"
STEP_START_EPOCH="${SCRIPT_START_EPOCH}"
STATUS="RUNNING"
ERROR_MESSAGE=""
VCF_COUNT="NA"
MONGO_BEFORE="NA"
MONGO_AFTER="NA"
RI_TOOLS_EXIT_CODE="NA"
REF_GENOME="NA"

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

mongo_count_dataset() {
  local dataset_id="$1"
  podman exec mongoprod mongosh "${MONGO_TLS_FLAGS[@]}" beacon --quiet --eval \
    "print(db.genomicVariations.countDocuments({datasetId: '${dataset_id}'}))"
}

write_metrics() {
  local script_end_epoch total_duration difference
  script_end_epoch="$(date +%s)"
  total_duration=$(( script_end_epoch - SCRIPT_START_EPOCH ))

  if [[ "${VCF_COUNT}" =~ ^[0-9]+$ && "${MONGO_AFTER}" =~ ^[0-9]+$ ]]; then
    difference=$(( VCF_COUNT - MONGO_AFTER ))
  else
    difference="NA"
  fi

  cat > "${METRICS_FILE}" <<EOF
run_timestamp	dataset_id	vcf_path	reference_genome	vcf_variants	mongo_before	mongo_after	vcf_minus_mongo	ri_tools_exit_code	status	total_duration_seconds	log_file	error_message
${RUN_TS}	${DATASET_ID}	${VCF_PATH}	${REF_GENOME}	${VCF_COUNT}	${MONGO_BEFORE}	${MONGO_AFTER}	${difference}	${RI_TOOLS_EXIT_CODE}	${STATUS}	${total_duration}	${LOG_FILE}	${ERROR_MESSAGE}
EOF

  if [ ! -f "${SUMMARY_FILE}" ]; then
    echo -e "run_timestamp\tdataset_id\tvcf_path\treference_genome\tvcf_variants\tmongo_before\tmongo_after\tvcf_minus_mongo\tri_tools_exit_code\tstatus\ttotal_duration_seconds\tlog_file\terror_message" > "${SUMMARY_FILE}"
  fi

  echo -e "${RUN_TS}\t${DATASET_ID}\t${VCF_PATH}\t${REF_GENOME}\t${VCF_COUNT}\t${MONGO_BEFORE}\t${MONGO_AFTER}\t${difference}\t${RI_TOOLS_EXIT_CODE}\t${STATUS}\t${total_duration}\t${LOG_FILE}\t${ERROR_MESSAGE}" >> "${SUMMARY_FILE}"
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

# -----------------------------
# Preparación de logs
# -----------------------------
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

log "=========================================="
log "Beacon ri-tools dataset loading"
log "Dataset: ${DATASET_ID}"
log "VCF: ${VCF_PATH}"
log "Run timestamp: ${RUN_TS}"
log "Log file: ${LOG_FILE}"
log "Metrics file: ${METRICS_FILE}"
log "Summary file: ${SUMMARY_FILE}"
log "=========================================="

# -----------------------------
# Paso 0: validaciones
# -----------------------------
start_step "validate_inputs"

if [ ! -f "${VCF_PATH}" ]; then
  fail "VCF no existe: ${VCF_PATH}"
fi

if [ ! -f "${CONF_PY}" ]; then
  fail "No existe conf.py: ${CONF_PY}"
fi

if [ ! -d "${FILES_TO_READ}" ]; then
  fail "No existe files_to_read/: ${FILES_TO_READ}"
fi

if ! command -v zcat >/dev/null 2>&1; then
  fail "zcat no está disponible en PATH"
fi

if ! command -v podman >/dev/null 2>&1; then
  fail "podman no está disponible en PATH"
fi

log "Inputs OK"
end_step

# -----------------------------
# Paso 1: contar variantes del VCF
# -----------------------------
start_step "count_vcf_variants"
VCF_COUNT="$(zcat "${VCF_PATH}" | grep -vc '^#' || true)"
log "VCF variants: ${VCF_COUNT}"

if ! [[ "${VCF_COUNT}" =~ ^[0-9]+$ ]]; then
  fail "No se pudo contar variantes en VCF: ${VCF_PATH}"
fi

if [ "${VCF_COUNT}" -eq 0 ]; then
  fail "El VCF no contiene variantes: ${VCF_PATH}"
fi
end_step

# -----------------------------
# Paso 2: editar conf.py
# -----------------------------
start_step "update_ritools_conf"
log "Actualizando datasetId en conf.py"
sed -i "s/datasetId='.*'/datasetId='${DATASET_ID}'/" "${CONF_PY}"

CURRENT_ID="$(grep '^datasetId' "${CONF_PY}" | sed "s/datasetId='\(.*\)'/\1/")"
if [ "${CURRENT_ID}" != "${DATASET_ID}" ]; then
  fail "No se pudo actualizar datasetId. Esperado '${DATASET_ID}', actual '${CURRENT_ID}'"
fi

REF_GENOME="$(grep '^reference_genome' "${CONF_PY}" | sed "s/reference_genome='\(.*\)'.*/\1/" || true)"
log "conf.py datasetId='${CURRENT_ID}' OK"
log "conf.py reference_genome='${REF_GENOME}'"
end_step

# -----------------------------
# Paso 3: preparar files_to_read
# -----------------------------
start_step "prepare_files_to_read"
log "Limpiando ${FILES_TO_READ}"
rm -f "${FILES_TO_READ}"/*.vcf.gz

log "Copiando VCF a files_to_read"
cp "${VCF_PATH}" "${FILES_TO_READ}/"
log "Contenido files_to_read:"
ls -lh "${FILES_TO_READ}" | tee -a "${LOG_FILE}"
end_step

# -----------------------------
# Paso 4: comprobar variantes preexistentes
# -----------------------------
start_step "check_existing_mongodb_records"
MONGO_BEFORE="$(mongo_count_dataset "${DATASET_ID}")"
log "MongoDB variants before load: ${MONGO_BEFORE}"

if [ "${MONGO_BEFORE}" -gt 0 ]; then
  log "AVISO: ya hay ${MONGO_BEFORE} variantes con datasetId '${DATASET_ID}' en MongoDB."
  read -r -p "Borrarlas y recargar? (s/N): " ans
  if [[ "${ans}" =~ ^[sSyY]$ ]]; then
    log "Borrando variantes existentes para datasetId='${DATASET_ID}'"
    podman exec mongoprod mongosh "${MONGO_TLS_FLAGS[@]}" beacon --quiet --eval \
      "db.genomicVariations.deleteMany({datasetId: '${DATASET_ID}'})" | tee -a "${LOG_FILE}"
    MONGO_BEFORE="0"
  else
    STATUS="CANCELLED"
    ERROR_MESSAGE="User cancelled because dataset already had MongoDB records"
    log "Cancelado por el usuario."
    write_metrics
    exit 0
  fi
fi
end_step

# -----------------------------
# Paso 5: ejecutar ri-tools
# -----------------------------
start_step "run_ri_tools"
log "Ejecutando ri-tools"
set +e
podman exec ri-tools python genomicVariations_vcf.py 2>&1 | tee -a "${LOG_FILE}"
RI_TOOLS_EXIT_CODE="${PIPESTATUS[0]}"
set -e
log "ri-tools exit code: ${RI_TOOLS_EXIT_CODE}"

if [ "${RI_TOOLS_EXIT_CODE}" -ne 0 ]; then
  fail "ri-tools terminó con exit code ${RI_TOOLS_EXIT_CODE}"
fi
end_step

# -----------------------------
# Paso 6: verificar inserción
# -----------------------------
start_step "verify_mongodb_records"
MONGO_AFTER="$(mongo_count_dataset "${DATASET_ID}")"
log "MongoDB variants after load: ${MONGO_AFTER}"
end_step

# -----------------------------
# Paso 7: evaluación final
# -----------------------------
start_step "evaluate_results"
log "=========================================="
log "Resumen para ${DATASET_ID}"
log "=========================================="
log "Variantes en VCF: ${VCF_COUNT}"
log "Variantes en MongoDB: ${MONGO_AFTER}"

if [ "${MONGO_AFTER}" -eq "${VCF_COUNT}" ]; then
  STATUS="OK"
  log "Estado: OK (coinciden)"
elif [ "${MONGO_AFTER}" -lt "${VCF_COUNT}" ]; then
  STATUS="WARNING"
  log "Estado: WARNING - faltan $(( VCF_COUNT - MONGO_AFTER )) variantes (posibles duplicados con otros datasets)"
else
  STATUS="ERROR"
  ERROR_MESSAGE="MongoDB has more records than VCF for dataset ${DATASET_ID}"
  log "Estado: ERROR - hay ${MONGO_AFTER} en BD pero el VCF solo tiene ${VCF_COUNT}."
  log "Posible contaminación de otro dataset. Revisa el log ${LOG_FILE}."
fi
end_step

# -----------------------------
# Paso 8: guardar métricas
# -----------------------------
start_step "write_metrics"
write_metrics
log "Metrics written: ${METRICS_FILE}"
log "Summary updated: ${SUMMARY_FILE}"
end_step

log "Finished with status: ${STATUS}"

if [ "${STATUS}" = "ERROR" ]; then
  exit 1
fi

exit 0
