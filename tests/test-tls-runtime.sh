#!/usr/bin/env bash
set -euo pipefail

# Independent TLS check: no PACS, shared certificates, or published port needed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${SCRIPT_DIR}/test-helpers.sh"
# shellcheck source=tests/integrity-helpers.sh
source "${SCRIPT_DIR}/integrity-helpers.sh"

PORT="${TLS_RUNTIME_PORT:-21114}"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || {
    print_fail 'TLS runtime port must be an integer from 1024 to 65535'
    exit 1
}
WORK=$(mktemp -d /tmp/tls-runtime-XXXXXX)
SCP_PID=''
cleanup() {
    local rc=$?
    trap - EXIT
    if [ -n "$SCP_PID" ]; then
        kill "$SCP_PID" 2>/dev/null || true
        wait "$SCP_PID" 2>/dev/null || true
    fi
    if [ "$rc" -ne 0 ]; then
        print_fail "TLS runtime failed; evidence retained in ${WORK}"
        tail -n 30 "${WORK}"/*.log 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
print_header 'Independent DICOM TLS Runtime'
echo "TLS runtime evidence: ${WORK}"
for tool in storescp echoscu storescu; do
    help_text=$("$tool" --help 2>&1 || true)
    [[ "$help_text" == *--enable-tls* ]] || {
        print_fail "${tool} has no TLS support"
        exit 1
    }
done
# Refuse an occupied port; never connect to or terminate an unrelated listener.
if nc -z 127.0.0.1 "$PORT"; then
    print_fail "TLS runtime port ${PORT} is already occupied"
    exit 1
fi
/usr/local/bin/gen-certs.sh "${WORK}/certs" > "${WORK}/certs.log" 2>&1
CERT="${WORK}/certs"
mkdir "${WORK}/received"
storescp -v +tls "${CERT}/server-key.pem" "${CERT}/server-cert.pem" \
    +cf "${CERT}/ca-cert.pem" -aet TLS_RUNTIME_SCP \
    -od "${WORK}/received" --filename-extension .dcm "$PORT" \
    > "${WORK}/server.log" 2>&1 &
SCP_PID=$!
TLS_ARGS=(+tls "${CERT}/client-key.pem" "${CERT}/client-cert.pem"
    +cf "${CERT}/ca-cert.pem" -aet TLS_RUNTIME_SCU -aec TLS_RUNTIME_SCP)
ready=false
for attempt in {1..10}; do
    kill -0 "$SCP_PID" 2>/dev/null || break
    if timeout 5 echoscu -to 2 "${TLS_ARGS[@]}" 127.0.0.1 "$PORT" \
            > "${WORK}/echo.log" 2>&1; then
        ready=true
        break
    fi
    echo "Waiting for TLS listener (attempt ${attempt})"
    sleep 0.2
done
[ "$ready" = true ] && kill -0 "$SCP_PID" 2>/dev/null || exit 1
TEST_TOTAL=1; TEST_PASSED=1
print_pass 'TLS runtime: authenticated C-ECHO succeeds'

# Generate private fixtures so this check is independent of PACS/test-all state.
GENERATE_PIXEL_DATA=true /usr/local/bin/generate-test-data.sh "${WORK}/input" \
    > "${WORK}/generate.log" 2>&1
mkdir "${WORK}/source"
source_files=("${WORK}/input/ct/"*.dcm)
cp "${source_files[0]}" "${WORK}/source/object.dcm"
dicom_manifest "${WORK}/expected.tsv" "${WORK}/source"
timeout 30 storescu -v -to 5 "${TLS_ARGS[@]}" 127.0.0.1 "$PORT" \
    "${WORK}/source/object.dcm" > "${WORK}/store.log" 2>&1
grep -Eq 'Store Response.*Success' "${WORK}/store.log"
dicom_manifest "${WORK}/actual.tsv" "${WORK}/received"
diff -u "${WORK}/expected.tsv" "${WORK}/actual.tsv"
TEST_TOTAL=$((TEST_TOTAL + 1)); TEST_PASSED=$((TEST_PASSED + 1))
print_pass 'TLS runtime: C-STORE preserves UID, metadata and complete PixelData'

plain_rc=0
timeout 10 echoscu -to 3 -aet TLS_RUNTIME_SCU -aec TLS_RUNTIME_SCP \
    127.0.0.1 "$PORT" > "${WORK}/plaintext.log" 2>&1 || plain_rc=$?
if [ "$plain_rc" -eq 0 ] || [ "$plain_rc" -eq 124 ] || [ "$plain_rc" -eq 137 ]; then
    print_fail "TLS runtime: plaintext was accepted or timed out (rc=${plain_rc})"
    exit 1
fi
# The negative result counts only while our listener remains alive and healthy.
kill -0 "$SCP_PID"
timeout 10 echoscu -to 3 "${TLS_ARGS[@]}" 127.0.0.1 "$PORT" \
    > "${WORK}/after-plaintext.log" 2>&1
TEST_TOTAL=$((TEST_TOTAL + 1)); TEST_PASSED=$((TEST_PASSED + 1))
print_pass 'TLS runtime: plaintext is refused and the TLS listener remains healthy'
print_summary 'TLS Runtime'
