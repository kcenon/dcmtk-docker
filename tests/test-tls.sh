#!/bin/bash
set -euo pipefail

# TLS Secure Transport Test
# Verifies that, under the TLS overlay, the primary PACS accepts a `+tls` C-ECHO
# using the generated client certificate and refuses a plaintext association.
#
# Run with the TLS overlay:
#   docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --build
#   docker compose -f docker-compose.yml -f docker-compose.tls.yml \
#       exec test-client /tests/test-tls.sh
#
# When TLS is not enabled (the default cleartext stack) the suite skips cleanly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${SCRIPT_DIR}/test-helpers.sh"

PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
CERT_DIR="${TLS_CERT_DIR:-/dicom/certs}"

print_header "TLS Secure Transport Tests"

# Skip cleanly when not running under the TLS overlay.
if [ "${TLS_ENABLED:-false}" != "true" ]; then
    print_skip "TLS not enabled - run with the docker-compose.tls.yml overlay"
    print_summary "TLS"
    exit 0
fi

# Requested TLS must fail when tooling/certificates are missing, not skip.
echo_help=$(echoscu --help 2>&1 || true)
if [[ "$echo_help" != *--enable-tls* ]]; then
    print_fail "echoscu has no TLS support"
    exit 1
fi
for cert in client-key.pem client-cert.pem ca-cert.pem; do
    if [ ! -s "${CERT_DIR}/${cert}" ]; then
        print_fail "Missing TLS material: ${CERT_DIR}/${cert}"
        exit 1
    fi
done
TLS_LOG_DIR=$(mktemp -d /tmp/tls-overlay-XXXXXX)
echo "TLS evidence: ${TLS_LOG_DIR}"

# Test 1: a +tls C-ECHO with the client certificate succeeds.
TEST_TOTAL=$((TEST_TOTAL + 1))
if timeout 20 echoscu -to 5 +tls "${CERT_DIR}/client-key.pem" "${CERT_DIR}/client-cert.pem" \
        +cf "${CERT_DIR}/ca-cert.pem" \
        -aet "${MY_AE}" -aec "${PACS_AE}" "${PACS_HOST}" "${PACS_PORT}" >"${TLS_LOG_DIR}/secure.log" 2>&1; then
    print_pass "TLS: C-ECHO over +tls succeeds with the client certificate"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    cat "${TLS_LOG_DIR}/secure.log"
    print_fail "TLS: C-ECHO over +tls failed"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Test 2: a plaintext C-ECHO is refused by the TLS-only PACS.
TEST_TOTAL=$((TEST_TOTAL + 1))
if timeout 15 echoscu -aet "${MY_AE}" -aec "${PACS_AE}" -to 5 "${PACS_HOST}" "${PACS_PORT}" >"${TLS_LOG_DIR}/plaintext.log" 2>&1; then
    print_fail "TLS: plaintext C-ECHO was unexpectedly accepted"
    TEST_FAILED=$((TEST_FAILED + 1))
else
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        print_fail "TLS: plaintext probe timed out instead of being refused"
        exit 1
    fi
    print_pass "TLS: plaintext C-ECHO is correctly refused"
    TEST_PASSED=$((TEST_PASSED + 1))
fi

print_summary "TLS"
[ "${TEST_FAILED}" -eq 0 ]
