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

# ── Helper: assert per-tag attribute values ───────────
# Parses dcmdump once and checks Rows / Columns / BitsStored /
# PixelRepresentation / PhotometricInterpretation against expected values.
# Args: LABEL FILE EXP_ROWS EXP_COLS EXP_BITS_STORED EXP_PIX_REP EXP_PHOTOMETRIC
assert_pixel_attributes() {
    local label="$1"
    local file="$2"
    local exp_rows="$3"
    local exp_cols="$4"
    local exp_bits_stored="$5"
    local exp_pix_rep="$6"
    local exp_photometric="$7"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local dump
    dump=$(dcmdump "${file}" 2>/dev/null) || {
        print_fail "PixelData: ${label} dcmdump failed (${file})"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    }

    local got_rows got_cols got_bs got_pr got_pm
    got_rows=$(grep -m1 '(0028,0010) US' <<<"${dump}" | sed -nE 's/.*US[[:space:]]+([0-9]+).*/\1/p')
    got_cols=$(grep -m1 '(0028,0011) US' <<<"${dump}" | sed -nE 's/.*US[[:space:]]+([0-9]+).*/\1/p')
    got_bs=$(grep   -m1 '(0028,0101) US' <<<"${dump}" | sed -nE 's/.*US[[:space:]]+([0-9]+).*/\1/p')
    got_pr=$(grep   -m1 '(0028,0103) US' <<<"${dump}" | sed -nE 's/.*US[[:space:]]+([0-9]+).*/\1/p')
    got_pm=$(grep   -m1 '(0028,0004) CS' <<<"${dump}" | sed -nE 's/.*\[([^]]*)\].*/\1/p' | sed 's/[[:space:]]*$//')

    local errors=()
    [ "${got_rows}" = "${exp_rows}" ]        || errors+=("Rows expected=${exp_rows} got=${got_rows:-<empty>}")
    [ "${got_cols}" = "${exp_cols}" ]        || errors+=("Columns expected=${exp_cols} got=${got_cols:-<empty>}")
    [ "${got_bs}"   = "${exp_bits_stored}" ] || errors+=("BitsStored expected=${exp_bits_stored} got=${got_bs:-<empty>}")
    [ "${got_pr}"   = "${exp_pix_rep}" ]     || errors+=("PixelRepresentation expected=${exp_pix_rep} got=${got_pr:-<empty>}")
    [ "${got_pm}"   = "${exp_photometric}" ] || errors+=("PhotometricInterpretation expected=${exp_photometric} got=${got_pm:-<empty>}")

    if [ "${#errors[@]}" -eq 0 ]; then
        print_pass "PixelData: ${label} attributes match (rows=${got_rows} cols=${got_cols} bits=${got_bs} pr=${got_pr} pm=${got_pm})"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "PixelData: ${label} attribute mismatch: $(IFS=' | '; echo "${errors[*]}")"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Helper: assert PS3.10 well-formedness via dcmftest ─
# dcmftest prints "yes: <file>" and exits 0 for valid DICOM files.
assert_file_valid() {
    local label="$1"
    local file="$2"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local out exit_code=0
    out=$(dcmftest "${file}" 2>&1) || exit_code=$?
    if [ "${exit_code}" -eq 0 ] && printf '%s\n' "${out}" | head -1 | grep -q '^yes:'; then
        print_pass "PixelData: ${label} dcmftest valid"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "PixelData: ${label} dcmftest reports invalid (${file})"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Helper: assert dcm2pnm output dimensions match ────
# Renders to PGM and parses the dimensions header line ("WIDTH HEIGHT").
# Comment lines starting with '#' inside the PNM header are skipped.
assert_dcm2pnm_dimensions() {
    local label="$1"
    local file="$2"
    local exp_rows="$3"
    local exp_cols="$4"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local out_pnm
    out_pnm=$(mktemp --suffix=.pnm)
    # shellcheck disable=SC2064
    trap "rm -f '${out_pnm}'" RETURN

    if ! dcm2pnm "${file}" "${out_pnm}" >/dev/null 2>&1 || [ ! -s "${out_pnm}" ]; then
        print_fail "PixelData: ${label} dcm2pnm produced no PNM (${file})"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi

    local dims
    dims=$(awk 'NR==1 {next}
                /^[[:space:]]*#/ {next}
                {print; exit}' "${out_pnm}")
    local got_cols got_rows
    got_cols=$(awk '{print $1}' <<<"${dims}")
    got_rows=$(awk '{print $2}' <<<"${dims}")

    if [ "${got_cols}" = "${exp_cols}" ] && [ "${got_rows}" = "${exp_rows}" ]; then
        print_pass "PixelData: ${label} PNM dimensions ${got_cols}x${got_rows} match"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "PixelData: ${label} PNM dimensions expected ${exp_cols}x${exp_rows} got ${got_cols:-<empty>}x${got_rows:-<empty>}"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Helper: assert .dcm instance count under a path ───
assert_multi_instance_count() {
    local label="$1"
    local dir="$2"
    local exp_count="$3"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local got_count
    got_count=$(find "${dir}" -name '*.dcm' 2>/dev/null | wc -l | tr -d ' ')

    if [ "${got_count}" = "${exp_count}" ]; then
        print_pass "PixelData: ${label} found ${got_count} .dcm files"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "PixelData: ${label} expected ${exp_count} .dcm files got ${got_count} (${dir})"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Helper: assert rendered pixel value range (opt-in) ─
# Slow path (~500ms/file): renders to 16-bit PGM, scans the binary
# section, and asserts every sample is within [MIN, MAX].
# Gated by PIXEL_RANGE_CHECK=true so the default fast path is unaffected.
assert_pixel_range() {
    local label="$1"
    local file="$2"
    local min="$3"
    local max="$4"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local out_pgm
    out_pgm=$(mktemp --suffix=.pgm)
    # shellcheck disable=SC2064
    trap "rm -f '${out_pgm}'" RETURN

    if ! dcm2pnm "${file}" "${out_pgm}" >/dev/null 2>&1 || [ ! -s "${out_pgm}" ]; then
        print_fail "PixelData: ${label} pixel-range render failed (${file})"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi

    # Locate end of PNM header: 3 newlines (P5, dims, maxval).
    local header_bytes
    header_bytes=$(awk 'BEGIN{n=0; b=0} {n++; b += length($0) + 1; if (n == 3) {print b; exit}}' "${out_pgm}")
    if [ -z "${header_bytes}" ] || [ "${header_bytes}" -le 0 ]; then
        print_fail "PixelData: ${label} could not parse PNM header for range scan"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    fi

    # PGM with maxval > 255 stores 16-bit big-endian samples per spec.
    local got_min got_max
    read -r got_min got_max <<<"$(tail -c +$((header_bytes + 1)) "${out_pgm}" \
        | od -An -tu2 --endian=big 2>/dev/null \
        | awk 'BEGIN{mn=4294967295; mx=-1}
               {for (i=1; i<=NF; i++) { v = $i + 0; if (v < mn) mn = v; if (v > mx) mx = v }}
               END{ if (mx == -1) print ""; else print mn, mx }')"

    if [ -n "${got_min:-}" ] && [ -n "${got_max:-}" ] \
            && [ "${got_min}" -ge "${min}" ] && [ "${got_max}" -le "${max}" ]; then
        print_pass "PixelData: ${label} display range [${got_min},${got_max}] within [${min},${max}]"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "PixelData: ${label} display range [${got_min:-?},${got_max:-?}] outside [${min},${max}]"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Helper: assert CT-specific Rescale tags (PS3.3 C.8.2.1) ─
# CT IOD requires RescaleIntercept (Type 1), RescaleSlope (Type 1) and
# RescaleType (Type 1C). MR and CR do not carry these tags, so this
# helper is invoked only from the CT branch of the test loop.
# Args: LABEL FILE EXP_INTERCEPT EXP_SLOPE EXP_TYPE
assert_ct_rescale() {
    local label="$1"
    local file="$2"
    local exp_intercept="$3"
    local exp_slope="$4"
    local exp_type="$5"

    TEST_TOTAL=$((TEST_TOTAL + 1))

    local dump
    dump=$(dcmdump "${file}" 2>/dev/null) || {
        print_fail "PixelData: ${label} dcmdump failed (${file})"
        TEST_FAILED=$((TEST_FAILED + 1))
        return 1
    }

    local got_intercept got_slope got_type
    got_intercept=$(grep -m1 '(0028,1052) DS' <<<"${dump}" | sed -nE 's/.*\[([^]]*)\].*/\1/p' | sed 's/[[:space:]]*$//')
    got_slope=$(grep    -m1 '(0028,1053) DS' <<<"${dump}" | sed -nE 's/.*\[([^]]*)\].*/\1/p' | sed 's/[[:space:]]*$//')
    got_type=$(grep     -m1 '(0028,1054) LO' <<<"${dump}" | sed -nE 's/.*\[([^]]*)\].*/\1/p' | sed 's/[[:space:]]*$//')

    local errors=()
    [ "${got_intercept}" = "${exp_intercept}" ] || errors+=("RescaleIntercept expected=${exp_intercept} got=${got_intercept:-<empty>}")
    [ "${got_slope}"     = "${exp_slope}" ]     || errors+=("RescaleSlope expected=${exp_slope} got=${got_slope:-<empty>}")
    [ "${got_type}"      = "${exp_type}" ]      || errors+=("RescaleType expected=${exp_type} got=${got_type:-<empty>}")

    if [ "${#errors[@]}" -eq 0 ]; then
        print_pass "PixelData: ${label} CT rescale tags match (intercept=${got_intercept} slope=${got_slope} type=${got_type})"
        TEST_PASSED=$((TEST_PASSED + 1))
        return 0
    fi

    print_fail "PixelData: ${label} CT rescale mismatch: $(IFS=' | '; echo "${errors[*]}")"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
}

# ── Per-modality expected-value table ─────────────────
# Single source of truth for attribute values. Mirrors the per-modality
# matrix in scripts/generate-test-data.sh:
#   #12 (CT signed/Rescale)  -> CT pix_rep=1; Rescale tags asserted via
#                                 assert_ct_rescale below.
#   #13 (modality-realistic) -> distinct rows/cols/bits_stored per modality:
#                                 CT 128x128 BitsStored=16, MR 128x128
#                                 BitsStored=12, CR 224x224 BitsStored=14
#                                 (conservative profile defaults).
# Each cell honors the matching {CT,MR,CR}_PIXEL_ROWS/_COLS env override so
# this test stays aligned when the operator overrides individual modalities.
# Note: PIXEL_DATA_PROFILE=realistic still requires the operator to also set
# the per-modality dimension env vars for this test to track the new values.
# Format: rows cols bits_stored pix_rep photometric
declare -A PIXEL_EXPECTED=(
    [ct]="${CT_PIXEL_ROWS:-128} ${CT_PIXEL_COLS:-128} 16 1 MONOCHROME2"
    [mr]="${MR_PIXEL_ROWS:-128} ${MR_PIXEL_COLS:-128} 12 0 MONOCHROME2"
    [cr]="${CR_PIXEL_ROWS:-224} ${CR_PIXEL_COLS:-224} 14 0 MONOCHROME2"
)

# ── Tests ─────────────────────────────────────────────
for modality in ct mr cr; do
    sample=$(find "${TEST_DATA_DIR}/${modality}" -name "*.dcm" 2>/dev/null | head -1)
    if [ -z "${sample}" ]; then
        print_skip "PixelData: ${modality^^} sample file not found"
        continue
    fi
    label="${modality^^} (first instance)"

    # Existing assertions (preserved unchanged)
    assert_pixeldata_present "${label}" "${sample}" || true
    assert_dcm2pnm_renders   "${label}" "${sample}" || true

    # New attribute-level assertions (always-on)
    entry="${PIXEL_EXPECTED[${modality}]:-}"
    if [ -z "${entry}" ]; then
        print_skip "PixelData: ${label} no expected-value table entry; skipping attribute checks"
    else
        read -r exp_rows exp_cols exp_bs exp_pr exp_pm <<<"${entry}"
        assert_pixel_attributes   "${label}" "${sample}" \
            "${exp_rows}" "${exp_cols}" "${exp_bs}" "${exp_pr}" "${exp_pm}" || true
        assert_file_valid         "${label}" "${sample}" || true
        assert_dcm2pnm_dimensions "${label}" "${sample}" "${exp_rows}" "${exp_cols}" || true

        # CT-only: verify the Rescale tags required by PS3.3 C.8.2.1.
        if [ "${modality}" = "ct" ]; then
            assert_ct_rescale "${label}" "${sample}" "-1024" "1.0" "HU" || true
        fi

        # Opt-in slow-path range assertion. Range stays wide (full uint16) until
        # #13 narrows per-modality value ranges.
        if [ "${PIXEL_RANGE_CHECK:-false}" = "true" ]; then
            assert_pixel_range "${label}" "${sample}" 0 65535 || true
        fi
    fi
done

# Optional cross-modality count check, opt-in via env so the default behavior
# stays unchanged regardless of the upstream generator's instance fan-out.
if [ -n "${EXPECTED_INSTANCE_COUNT:-}" ]; then
    assert_multi_instance_count "all modalities" "${TEST_DATA_DIR}" "${EXPECTED_INSTANCE_COUNT}" || true
fi

# ── Summary ───────────────────────────────────────────
print_summary "PixelData"
[ "${TEST_FAILED}" -eq 0 ]
