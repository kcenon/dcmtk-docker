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
source "${SCRIPT_DIR}/test-helpers.sh"

PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
CERT_DIR="${TLS_CERT_DIR:-/dicom/certs}"

print_header "TLS Secure Transport Tests"

# Skip cleanly when not running under the TLS overlay.
if [ "${TLS_ENABLED:-false}" != "true" ] || [ ! -f "${CERT_DIR}/client-cert.pem" ]; then
    print_skip "TLS not enabled - run with the docker-compose.tls.yml overlay"
    print_summary "TLS"
    exit 0
fi

# Skip when this dcmtk build has no TLS support. The stock Debian apt dcmtk is
# not linked against OpenSSL, so +tls is unavailable; the TLS profile needs a
# TLS-capable (source-built / OpenSSL-linked) dcmtk image.
if ! echoscu --help 2>&1 | grep -q -- '--enable-tls'; then
    print_skip "this dcmtk build has no TLS support (stock Debian apt dcmtk is not OpenSSL-linked)"
    print_summary "TLS"
    exit 0
fi

# Test 1: a +tls C-ECHO with the client certificate succeeds.
TEST_TOTAL=$((TEST_TOTAL + 1))
if echoscu +tls "${CERT_DIR}/client-key.pem" "${CERT_DIR}/client-cert.pem" \
        +cf "${CERT_DIR}/ca-cert.pem" \
        -aet "${MY_AE}" -aec "${PACS_AE}" "${PACS_HOST}" "${PACS_PORT}" >/dev/null 2>&1; then
    print_pass "TLS: C-ECHO over +tls succeeds with the client certificate"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "TLS: C-ECHO over +tls failed"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Test 2: a plaintext C-ECHO is refused by the TLS-only PACS.
TEST_TOTAL=$((TEST_TOTAL + 1))
if echoscu -aet "${MY_AE}" -aec "${PACS_AE}" -to 5 "${PACS_HOST}" "${PACS_PORT}" >/dev/null 2>&1; then
    print_fail "TLS: plaintext C-ECHO was unexpectedly accepted"
    TEST_FAILED=$((TEST_FAILED + 1))
else
    print_pass "TLS: plaintext C-ECHO is correctly refused"
    TEST_PASSED=$((TEST_PASSED + 1))
fi

print_summary "TLS"
[ "${TEST_FAILED}" -eq 0 ]
