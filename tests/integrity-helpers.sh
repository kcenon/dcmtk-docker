#!/bin/bash
# Source after test-helpers.sh. Sorted TSV: SOP UID, Study UID, Series UID,
# SHA256(selected metadata + full PixelData), excluding Part 10 headers.

dicom_manifest() {
    local output="$1"
    shift
    local file dump uid study series hash
    dump="${output}.dump"
    find "$@" -type f -name '*.dcm' -print0 > "${output}.files" || return 1
    : > "${output}"
    while IFS= read -r -d '' file; do
        dcmdump +L +Un +P 0008,0016 +P 0008,0018 +P 0010,0010 +P 0010,0020 \
            +P 0020,000d +P 0020,000e +P 0028,0002 +P 0028,0004 \
            +P 0028,0010 +P 0028,0011 +P 0028,0100 +P 0028,0101 \
            +P 0028,0102 +P 0028,0103 +P 7fe0,0010 "${file}" > "${dump}" || return 1
        uid=$(sed -nE '/^\(0008,0018\)/s/.*\[([0-9.]+)\].*/\1/p' "${dump}")
        study=$(sed -nE '/^\(0020,000d\)/s/.*\[([0-9.]+)\].*/\1/p' "${dump}")
        series=$(sed -nE '/^\(0020,000e\)/s/.*\[([0-9.]+)\].*/\1/p' "${dump}")
        if [ -z "${uid}" ] || [ -z "${study}" ] || [ -z "${series}" ]; then
            echo "ERROR: missing identity in ${file}" >&2
            return 1
        fi
        hash=$(sha256sum "${dump}")
        printf '%s\t%s\t%s\t%s\n' "${uid}" "${study}" "${series}" "${hash%% *}" >> "${output}"
    done < "${output}.files"
    LC_ALL=C sort -o "${output}" "${output}" || return 1
    if [ -n "$(cut -f1 "${output}" | uniq -d)" ]; then
        echo "ERROR: duplicate SOP Instance UIDs in ${output}" >&2
        return 1
    fi
    rm -f "${dump}" "${output}.files"
}

# Query each expected series at IMAGE level, excluding echoed request keys.
query_instance_uids() {
    local expected="$1" output="$2" host="$3" port="$4" ae="$5"
    local study series log index=0
    cut -f2,3 "${expected}" | LC_ALL=C sort -u > "${output}.series"
    : > "${output}"
    while IFS=$'\t' read -r study series; do
        index=$((index + 1))
        log="${output}.query-${index}.log"
        timeout "${TIMEOUT_SEC:-60}" findscu -v -S -to 5 -ta 10 -td 20 \
            -aet "${MY_AE:-TEST_SCU}" -aec "${ae}" "${host}" "${port}" \
            -k QueryRetrieveLevel=IMAGE -k "StudyInstanceUID=${study}" \
            -k "SeriesInstanceUID=${series}" -k SOPInstanceUID > "${log}" 2>&1 || return 1
        tr -d '\000' < "${log}" > "${log}.text"
        grep -Eq '(Final Find Response|Find Response:).*\(Success\)' "${log}.text" || return 1
        sed -nE '/\(0008,0018\) UI/s/.*\[([0-9.]+)\].*/\1/p' "${log}.text" >> "${output}"
    done < "${output}.series"
    LC_ALL=C sort -o "${output}" "${output}"
}

# The caller owns the isolated test receiver. Concurrent suites cannot share it.
retrieve_manifest() {
    local expected="$1" output="$2" host="$3" port="$4" ae="$5"
    local study log index=0
    local receiver="${STORESCP_STORAGE_DIR:-/dicom/received}"
    receiver_cleanup_storage "${receiver}" || return 1
    cut -f2 "${expected}" | LC_ALL=C sort -u > "${output}.studies"
    while IFS= read -r study; do
        index=$((index + 1))
        log="${output}.move-${index}.log"
        timeout "${TIMEOUT_SEC:-60}" movescu -v -S -to 5 -ta 10 -td 20 \
            -aet "${MY_AE:-TEST_SCU}" -aec "${ae}" \
            -aem "${STORESCP_AE_TITLE:-STORE_SCP}" "${host}" "${port}" \
            -k QueryRetrieveLevel=STUDY -k "StudyInstanceUID=${study}" > "${log}" 2>&1 || return 1
        grep -Eq '(Final Move Response|Move Response:).*\(Success\)' "${log}" || return 1
    done < "${output}.studies"
    dicom_manifest "${output}" "${receiver}"
}

verify_instance_integrity() {
    local expected="$1" prefix="$2" host="$3" port="$4" ae="$5"
    cut -f1 "${expected}" > "${prefix}.expected-uids"
    query_instance_uids "${expected}" "${prefix}.query-uids" "${host}" "${port}" "${ae}" || return 1
    diff -u "${prefix}.expected-uids" "${prefix}.query-uids" || return 1
    retrieve_manifest "${expected}" "${prefix}.received" "${host}" "${port}" "${ae}" || return 1
    diff -u "${expected}" "${prefix}.received"
}
