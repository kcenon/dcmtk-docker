#!/bin/bash
set -e

# Wait for a DICOM SCP to become reachable via C-ECHO.
# Usage: wait-for-pacs.sh <host> <port> [ae_title] [max_retries] [interval]

HOST="${1:?Usage: wait-for-pacs.sh <host> <port> [ae_title] [max_retries] [interval]}"
PORT="${2:?Usage: wait-for-pacs.sh <host> <port> [ae_title] [max_retries] [interval]}"
AE_TITLE="${3:-ANY-SCP}"
MAX_RETRIES="${4:-30}"
INTERVAL="${5:-2}"

echo "Waiting for PACS at ${HOST}:${PORT} (AE: ${AE_TITLE})..."

for i in $(seq 1 "${MAX_RETRIES}"); do
    if echoscu -aec "${AE_TITLE}" "${HOST}" "${PORT}" 2>/dev/null; then
        echo "PACS ${HOST}:${PORT} is ready (attempt ${i}/${MAX_RETRIES})"
        exit 0
    fi
    echo "  Attempt ${i}/${MAX_RETRIES} - not ready, retrying in ${INTERVAL}s..."
    sleep "${INTERVAL}"
done

echo "ERROR: PACS ${HOST}:${PORT} not ready after $((MAX_RETRIES * INTERVAL))s"
exit 1
