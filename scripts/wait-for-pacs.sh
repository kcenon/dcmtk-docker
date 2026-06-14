#!/bin/bash
set -euo pipefail

# Wait for a DICOM SCP to become reachable via C-ECHO.
# Usage: wait-for-pacs.sh <host> <port> [ae_title] [max_retries] [interval]

HOST="${1:?Usage: wait-for-pacs.sh <host> <port> [ae_title] [max_retries] [interval]}"
PORT="${2:?Usage: wait-for-pacs.sh <host> <port> [ae_title] [max_retries] [interval]}"
AE_TITLE="${3:-ANY-SCP}"
MAX_RETRIES="${4:-30}"
INTERVAL="${5:-2}"

echo "Waiting for PACS at ${HOST}:${PORT} (AE: ${AE_TITLE})..."

# Capture echoscu's stderr so a permanent misconfiguration (e.g. an AE Title
# the SCP refuses) can be distinguished from transient non-readiness instead of
# being swallowed for the whole retry window. The capture is reset each attempt
# and only surfaced on the final failure.
ECHOSCU_ERR="$(mktemp)"
trap 'rm -f "${ECHOSCU_ERR}"' EXIT

for i in $(seq 1 "${MAX_RETRIES}"); do
    if echoscu -aec "${AE_TITLE}" "${HOST}" "${PORT}" 2>"${ECHOSCU_ERR}"; then
        echo "PACS ${HOST}:${PORT} is ready (attempt ${i}/${MAX_RETRIES})"
        exit 0
    fi
    echo "  Attempt ${i}/${MAX_RETRIES} - not ready, retrying in ${INTERVAL}s..."
    sleep "${INTERVAL}"
done

echo "ERROR: PACS ${HOST}:${PORT} not ready after $((MAX_RETRIES * INTERVAL))s" >&2
if [ -s "${ECHOSCU_ERR}" ]; then
    echo "       last echoscu error output:" >&2
    sed 's/^/       /' "${ECHOSCU_ERR}" >&2
fi
exit 1
