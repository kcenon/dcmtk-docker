#!/bin/bash
set -e

# DCMTK PACS Test Environment - Entrypoint Script
# Dispatches to the appropriate service based on the ROLE environment variable.

# ── Defaults ─────────────────────────────────────────
ROLE="${ROLE:-pacs-server}"
AE_TITLE="${AE_TITLE:-DCMTK_PACS}"
DICOM_PORT="${DICOM_PORT:-11112}"
STORAGE_DIR="${STORAGE_DIR:-/dicom/db}"
LOG_LEVEL="${LOG_LEVEL:-info}"
GENERATE_TEST_DATA="${GENERATE_TEST_DATA:-false}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"
CONFIG_TEMPLATE="${CONFIG_TEMPLATE:-/etc/dcmtk/dcmqrscp-primary.cfg.template}"

# Map LOG_LEVEL to DCMTK --log-level values
map_log_level() {
    case "${LOG_LEVEL}" in
        debug) echo "debug" ;;
        info)  echo "info"  ;;
        warn)  echo "warn"  ;;
        error) echo "error" ;;
        *)     echo "info"  ;;
    esac
}

DCMTK_LOG_LEVEL=$(map_log_level)

# ── Logging helpers ──────────────────────────────────
log_info()  { echo "[entrypoint] INFO:  $*"; }
log_warn()  { echo "[entrypoint] WARN:  $*" >&2; }
log_error() { echo "[entrypoint] ERROR: $*" >&2; }

# ── Generate test data ───────────────────────────────
maybe_generate_test_data() {
    if [ "${GENERATE_TEST_DATA}" = "true" ]; then
        if [ -x /usr/local/bin/generate-test-data.sh ]; then
            log_info "Generating synthetic test data..."
            /usr/local/bin/generate-test-data.sh "${TEST_DATA_DIR}"
        else
            log_info "generate-test-data.sh not found, skipping test data generation"
        fi
    fi
}

# ── Role: pacs-server (dcmqrscp) ────────────────────
start_pacs_server() {
    log_info "Starting PACS server: AE_TITLE=${AE_TITLE}, PORT=${DICOM_PORT}"

    # Create storage directory for this AE
    mkdir -p "${STORAGE_DIR}/${AE_TITLE}"

    # Process config template with envsubst
    if [ -f "${CONFIG_TEMPLATE}" ]; then
        log_info "Processing config template: ${CONFIG_TEMPLATE}"
        envsubst < "${CONFIG_TEMPLATE}" > /tmp/dcmqrscp.cfg
    else
        log_error "Config template not found: ${CONFIG_TEMPLATE}"
        exit 1
    fi

    # Security check: warn if rendered config uses 'ANY' Peers
    # (test default; not safe for production - see config/dcmqrscp-production.cfg.example)
    if grep -Eq '^[[:space:]]*[^#].*[[:space:]]ANY[[:space:]]*$' /tmp/dcmqrscp.cfg; then
        log_warn "dcmqrscp AETable uses 'ANY' Peers - any SCU may connect without AE Title verification."
        log_warn "This is TEST-ONLY. For production, see config/dcmqrscp-production.cfg.example."
    fi

    # Generate test data if enabled
    maybe_generate_test_data

    # If test data was generated, register it with the PACS database
    if [ "${GENERATE_TEST_DATA}" = "true" ] && [ -d "${TEST_DATA_DIR}" ]; then
        local dcm_count
        dcm_count=$(find "${TEST_DATA_DIR}" -name "*.dcm" 2>/dev/null | wc -l)
        if [ "$dcm_count" -gt 0 ]; then
            log_info "Registering ${dcm_count} test DICOM files with PACS database..."
            find "${TEST_DATA_DIR}" -name "*.dcm" -exec \
                dcmqridx "${STORAGE_DIR}/${AE_TITLE}" {} + 2>/dev/null || true
        fi
    fi

    log_info "Starting dcmqrscp on port ${DICOM_PORT}..."
    exec dcmqrscp --log-level "${DCMTK_LOG_LEVEL}" \
        -c /tmp/dcmqrscp.cfg "${DICOM_PORT}"
}

# ── Role: storescp (C-STORE receiver) ────────────────
start_storescp() {
    log_info "Starting Store SCP: AE_TITLE=${AE_TITLE}, PORT=${DICOM_PORT}"

    mkdir -p "${STORAGE_DIR}"

    log_info "Starting storescp on port ${DICOM_PORT}..."
    exec storescp --log-level "${DCMTK_LOG_LEVEL}" \
        --output-directory "${STORAGE_DIR}" \
        --aetitle "${AE_TITLE}" \
        --sort-on-study-uid prefix \
        "${DICOM_PORT}"
}

# ── Role: test-client ────────────────────────────────
start_test_client() {
    log_info "Starting test client: AE_TITLE=${AE_TITLE}"

    # Generate test data if enabled
    maybe_generate_test_data

    log_info "Test client ready. Available tools: echoscu, storescu, findscu, movescu, getscu"
    log_info "Container will stay alive. Use 'docker compose exec test-client <command>' to run tools."
    exec sleep infinity
}

# ── Role: custom ─────────────────────────────────────
start_custom() {
    log_info "Custom mode: executing command: $*"
    exec "$@"
}

# ── Dispatch ─────────────────────────────────────────
log_info "Role: ${ROLE}"

case "${ROLE}" in
    pacs-server)
        start_pacs_server
        ;;
    storescp)
        start_storescp
        ;;
    test-client)
        start_test_client
        ;;
    custom)
        start_custom "$@"
        ;;
    *)
        log_error "Unknown role: ${ROLE}"
        log_error "Valid roles: pacs-server, storescp, test-client, custom"
        exit 1
        ;;
esac
