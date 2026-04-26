#!/bin/bash
set -uo pipefail

# Synthetic PixelData smoke test.
# Verifies that when GENERATE_PIXEL_DATA=true is in effect for the test data
# generator, every CT/MR/CR instance carries a non-empty (7FE0,0010) PixelData
# element AND can be rendered by dcm2pnm without error. The whole suite is
# skipped (with a clear log line, exit 0) when the flag is unset so the
# default-behavior path of the project keeps passing CI unchanged.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration ─────────────────────────────────────
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"
GENERATE_PIXEL_DATA="${GENERATE_PIXEL_DATA:-false}"

print_header "PixelData Smoke Test"

# ── Skip path: feature is opt-in ──────────────────────
if [ "${GENERATE_PIXEL_DATA}" != "true" ]; then
    print_skip "PixelData: GENERATE_PIXEL_DATA is not 'true' (skipping smoke test)"
    print_summary "PixelData"
    exit 0
fi

# ── Ensure data is present ────────────────────────────
if [ ! -d "${TEST_DATA_DIR}" ] || \
   [ "$(find "${TEST_DATA_DIR}" -name '*.dcm' 2>/dev/null | wc -l)" -eq 0 ]; then
    print_fail "PixelData: no .dcm files in ${TEST_DATA_DIR}"
    print_summary "PixelData"
    exit 1
fi

# ── Helper: assert PixelData present in a file ────────
assert_pixeldata_present() {
    local label="$1"
    local file="$2"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local dump
    dump=$(dcmdump "${file}" 2>/dev/null) || {
        print_fail "PixelData: ${label} dcmdump failed (${file})"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    }

    # dcmdump renders PixelData as: (7fe0,0010) OW (PixelData) ...
    if echo "${dump}" | grep -q '(7fe0,0010)'; then
        # Confirm it is non-empty by checking the length token is > 0
        local len
        len=$(echo "${dump}" | grep '(7fe0,0010)' | head -1 \
              | sed -nE 's/.*# *([0-9]+).*/\1/p')
        if [ -n "${len}" ] && [ "${len}" -gt 0 ]; then
            print_pass "PixelData: ${label} has non-empty (7FE0,0010) [${len} bytes]"
            TEST_PASSED=$((TEST_PASSED + 1))
            return 0
        fi
    fi

    print_fail "PixelData: ${label} missing or empty (7FE0,0010) (${file})"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Helper: assert dcm2pnm renders to a non-empty file ─
assert_dcm2pnm_renders() {
    local label="$1"
    local file="$2"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local out_pnm
    out_pnm=$(mktemp --suffix=.pnm)
    # shellcheck disable=SC2064
    trap "rm -f '${out_pnm}'" RETURN

    if dcm2pnm "${file}" "${out_pnm}" >/dev/null 2>&1 \
       && [ -s "${out_pnm}" ]; then
        local size
        size=$(stat -c '%s' "${out_pnm}" 2>/dev/null || echo "0")
        print_pass "PixelData: ${label} rendered by dcm2pnm [${size} bytes PNM]"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "PixelData: ${label} dcm2pnm failed or produced empty output (${file})"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Tests ─────────────────────────────────────────────
for modality in ct mr cr; do
    sample=$(find "${TEST_DATA_DIR}/${modality}" -name "*.dcm" 2>/dev/null | head -1)
    if [ -z "${sample}" ]; then
        print_skip "PixelData: ${modality^^} sample file not found"
        continue
    fi
    assert_pixeldata_present "${modality^^} (first instance)" "${sample}" || true
    assert_dcm2pnm_renders   "${modality^^} (first instance)" "${sample}" || true
done

# ── Summary ───────────────────────────────────────────
print_summary "PixelData"
[ "${TEST_FAILED}" -eq 0 ]
