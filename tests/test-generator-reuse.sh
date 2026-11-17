#!/bin/bash
set -uo pipefail

# Test data generator reuse check (#138).
# Runs scripts/generate-test-data.sh against scratch folders and verifies when
# it reuses existing output and when it writes the output again. Only its own
# ct/, mr/ and cr/ folders count, and output that is incomplete or was made
# with other settings (PixelData on or off, other Rows/Columns, another
# OID_ROOT) is written again in place. The real dump2dcm and dcmdump are used,
# so run it in the test-client image:
#   docker compose exec -T test-client /tests/test-generator-reuse.sh
# GENERATOR selects another copy of the generator (used for mutation checks).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

GENERATOR="${GENERATOR:-/usr/local/bin/generate-test-data.sh}"
EXPECTED_OWN=$((MANIFEST_CT_COUNT + MANIFEST_MR_COUNT + MANIFEST_CR_COUNT))
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

SETTINGS_VARS=(GENERATE_PIXEL_DATA PIXEL_DATA_PROFILE OID_ROOT
               CT_PIXEL_ROWS CT_PIXEL_COLS MR_PIXEL_ROWS MR_PIXEL_COLS
               CR_PIXEL_ROWS CR_PIXEL_COLS)

# gen DIR [VAR=value ...]: run the generator with only the given settings, so
# the container's own GENERATE_PIXEL_DATA or OID_ROOT cannot leak in. The
# generator log goes to DIR.log.
gen() {
    local dir="$1" v
    shift
    local unset_args=()
    for v in "${SETTINGS_VARS[@]}"; do
        unset_args+=(-u "${v}")
    done
    if ! env "${unset_args[@]}" "$@" bash "${GENERATOR}" "${dir}" > "${dir}.log" 2>&1; then
        echo "generator failed: $(tail -1 "${dir}.log")"
        return 1
    fi
}

own_files() {
    find "$1/ct" "$1/mr" "$1/cr" -maxdepth 1 -name '*.dcm' 2>/dev/null | sort
}

own_count() {
    own_files "$1" | wc -l
}

# Value of one tag in FILE without brackets; empty when the tag is absent.
tag_value() {
    dcmdump -q +P "$2" "$1" 2>/dev/null | awk '{ print $3 }' | tr -d '[]'
}

pixel_count() {
    local f n=0
    while IFS= read -r f; do
        [ -n "$(dcmdump -q +P 7fe0,0010 "${f}" 2>/dev/null)" ] && n=$((n + 1))
    done < <(own_files "$1")
    echo "${n}"
}

# Date every own file back to 2000, so a later rewrite shows up as a new mtime.
age_own_files() {
    own_files "$1" | xargs -r touch -d '2000-01-01 00:00:00'
}

rewritten_count() {
    find "$1/ct" "$1/mr" "$1/cr" -maxdepth 1 -name '*.dcm' -newermt '2001-01-01' 2>/dev/null | wc -l
}

# Run one scenario; on failure print its last output line as the reason.
check() {
    local label="$1" out rc=0
    shift
    TEST_TOTAL=$((TEST_TOTAL + 1))
    out=$("$@" 2>&1) || rc=$?
    if [ "${rc}" -eq 0 ]; then
        TEST_PASSED=$((TEST_PASSED + 1))
        print_pass "Generator: ${label}"
    else
        TEST_FAILED=$((TEST_FAILED + 1))
        print_fail "Generator: ${label} ($(printf '%s\n' "${out}" | tail -1))"
    fi
}

# ── Scenarios ─────────────────────────────────────────
s1_empty_folder() {
    local d="${WORK_DIR}/s1" n
    gen "${d}" || return 1
    n=$(own_count "${d}")
    [ "${n}" -eq "${EXPECTED_OWN}" ] || { echo "own files: ${n}, expected ${EXPECTED_OWN}"; return 1; }
    n=$(pixel_count "${d}")
    [ "${n}" -eq 0 ] || { echo "files with PixelData: ${n}, expected 0"; return 1; }
}

# Same settings twice: the second run must leave every file alone.
s2_same_settings() {
    local d="${WORK_DIR}/s2-$1" n
    shift
    gen "${d}" "$@" || return 1
    age_own_files "${d}"
    gen "${d}" "$@" || return 1
    n=$(rewritten_count "${d}")
    [ "${n}" -eq 0 ] || { echo "rewritten files: ${n}, expected 0"; return 1; }
    grep -q 'skipping' "${d}.log" || { echo "no skip line in the generator log"; return 1; }
}

# A user's own DICOM files in the data root and in another folder must not
# stop generation, and must stay as they were.
s3_user_files() {
    local d="${WORK_DIR}/s3" r="${WORK_DIR}/s3-ref" n before after
    gen "${r}" || return 1
    mkdir -p "${d}/custom"
    cp "${r}/ct/ct_pat001_1.dcm" "${d}/own.dcm"
    cp "${r}/mr/mr_pat002_s1_1.dcm" "${d}/custom/own2.dcm"
    before=$(sha256sum "${d}/own.dcm" "${d}/custom/own2.dcm")
    gen "${d}" || return 1
    n=$(own_count "${d}")
    [ "${n}" -eq "${EXPECTED_OWN}" ] || { echo "own files: ${n}, expected ${EXPECTED_OWN}"; return 1; }
    after=$(sha256sum "${d}/own.dcm" "${d}/custom/own2.dcm")
    [ "${before}" = "${after}" ] || { echo "user files changed"; return 1; }
}

# Output made with other settings is written again: FROM settings, then TO
# settings, then CHECK prints a reason and fails when the result is wrong.
s_rewrite() {
    local d="${WORK_DIR}/$1" from="$2" to="$3" check_fn="$4" n
    # shellcheck disable=SC2086
    gen "${d}" ${from} || return 1
    age_own_files "${d}"
    # shellcheck disable=SC2086
    gen "${d}" ${to} || return 1
    n=$(rewritten_count "${d}")
    [ "${n}" -eq "${EXPECTED_OWN}" ] || { echo "rewritten files: ${n}, expected ${EXPECTED_OWN}"; return 1; }
    "${check_fn}" "${d}"
}

all_have_pixels() {
    local n
    n=$(pixel_count "$1")
    [ "${n}" -eq "${EXPECTED_OWN}" ] || { echo "files with PixelData: ${n}, expected ${EXPECTED_OWN}"; return 1; }
}

none_have_pixels() {
    local n
    n=$(pixel_count "$1")
    [ "${n}" -eq 0 ] || { echo "files with PixelData: ${n}, expected 0"; return 1; }
}

ct_columns_are_64() {
    local f cols
    for f in "$1"/ct/*.dcm; do
        cols=$(tag_value "${f}" 0028,0011)
        [ "${cols}" = 64 ] || { echo "${f##*/} Columns ${cols:-absent}, expected 64"; return 1; }
    done
}

uids_use_new_root() {
    local f uid
    while IFS= read -r f; do
        uid=$(tag_value "${f}" 0008,0018)
        case "${uid}" in
            2.25.138.*) ;;
            *) echo "${f##*/} SOP Instance UID ${uid}, expected root 2.25.138"; return 1 ;;
        esac
    done < <(own_files "$1")
}

# A missing own file means the output is incomplete.
s8_missing_file() {
    local d="${WORK_DIR}/s8" n
    gen "${d}" || return 1
    rm -f "${d}/cr/cr_pat003_${MANIFEST_CR_COUNT}.dcm"
    gen "${d}" || return 1
    n=$(own_count "${d}")
    [ "${n}" -eq "${EXPECTED_OWN}" ] || { echo "own files: ${n}, expected ${EXPECTED_OWN}"; return 1; }
}

print_header "Test Data Generator Reuse"

check "empty folder is generated" s1_empty_folder
check "same settings reuse the output (metadata only)" s2_same_settings meta
check "same settings reuse the output (PixelData)" s2_same_settings pixel GENERATE_PIXEL_DATA=true
check "user files elsewhere do not stop generation" s3_user_files
check "turning PixelData on writes the output again" \
    s_rewrite s4 "" "GENERATE_PIXEL_DATA=true" all_have_pixels
check "turning PixelData off writes the output again" \
    s_rewrite s5 "GENERATE_PIXEL_DATA=true" "" none_have_pixels
check "new Columns write the output again" \
    s_rewrite s6 "GENERATE_PIXEL_DATA=true" "GENERATE_PIXEL_DATA=true CT_PIXEL_COLS=64" ct_columns_are_64
check "new OID_ROOT writes the output again" \
    s_rewrite s7 "" "OID_ROOT=2.25.138" uids_use_new_root
check "a missing own file writes the output again" s8_missing_file

print_summary "Generator"
[ "${TEST_FAILED}" -eq 0 ]
