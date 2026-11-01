#!/usr/bin/env bash
# Sourced by test-transfer-syntax.sh; each command failure must propagate even
# when run_test invokes a function in a conditional/subshell.

restore_transfer_source() {
    [ "${RESTORE_NEEDED}" = true ] || return 0
    timeout 30 storescu -v -xe -to 5 -aet "${MY_AE}" -aec "${PACS_AE}" \
        "${PACS_HOST}" "${PACS_PORT}" "${SOURCE_FILE}" \
        > "${WORKDIR}/restore.log" 2>&1 || return 1
    grep -Eq 'Store Response.*Success' "${WORKDIR}/restore.log" || return 1
    RESTORE_NEEDED=false
}

cleanup_transfer_syntax() {
    local rc=$?
    trap - EXIT
    if ! restore_transfer_source; then
        print_fail "Transfer Syntax: failed to restore source; see ${WORKDIR}/restore.log"
        rc=1
    fi
    # Keep codec, negotiation, and retrieval evidence for CI artifacts.
    exit "$rc"
}

compress_source() {
    mkdir -p "${WORKDIR}/original" "${WORKDIR}/decoded" || return 1
    dcmdump +P 7fe0,0010 "${SOURCE_FILE}" > "${WORKDIR}/pixel-check.log" || return 1
    grep -q PixelData "${WORKDIR}/pixel-check.log" || {
        echo "Compressed tests require GENERATE_PIXEL_DATA=true" >&2
        return 1
    }
    cp "${SOURCE_FILE}" "${WORKDIR}/original/source.dcm" || return 1
    dicom_manifest "${WORKDIR}/original.tsv" "${WORKDIR}/original" || return 1
    timeout 30 "${COMPRESSOR[@]}" +un "${SOURCE_FILE}" "${WORKDIR}/compressed.dcm" \
        > "${WORKDIR}/codec.log" 2>&1 || return 1
    # Never add an extra SOP to the fixture catalog. Lossless codecs support +un.
    local uid expected
    expected=$(cut -f1 "${WORKDIR}/original.tsv")
    uid=$(dcmdump -Un +P 0008,0018 "${WORKDIR}/compressed.dcm" \
        | sed -nE 's/.*\[([0-9.]+)\].*/\1/p') || return 1
    [ "$uid" = "$expected" ]
}

store_compressed() {
    # One required SOP class and combined context: the accepted transfer syntax
    # is the actual C-STORE encoding, with no alternative accepted context.
    timeout 30 storescu -d -R +C "${PROPOSE_FLAG}" -to 5 \
        -aet "${MY_AE}" -aec "${PACS_AE}" "${PACS_HOST}" "${PACS_PORT}" \
        "${WORKDIR}/compressed.dcm" > "${WORKDIR}/negotiation.log" 2>&1 || return 1
    grep -Eq 'Message Type[[:space:]]*: C-STORE RSP' "${WORKDIR}/negotiation.log" || return 1
    grep -Eq 'DIMSE Status[[:space:]]*: 0x0000: Success' "${WORKDIR}/negotiation.log" || return 1
    local symbol
    symbol=$(dcmdump +P 0002,0010 "${WORKDIR}/compressed.dcm" \
        | sed -nE 's/.*UI =([^ ]+).*/\1/p') || return 1
    [ -n "$symbol" ] || return 1
    grep -F "Accepted Transfer Syntax: =$symbol" "${WORKDIR}/negotiation.log"
}

stored_compressed() {
    local expected uid file found=0 ts
    expected=$(cut -f1 "${WORKDIR}/original.tsv")
    find "/dicom/primary-db/${PACS_AE}" -type f -name '*.dcm' -print0 \
        > "${WORKDIR}/archive-files" || return 1
    while IFS= read -r -d '' file; do
        uid=$(dcmdump -Un +P 0008,0018 "$file" | sed -nE 's/.*\[([0-9.]+)\].*/\1/p') || return 1
        if [ "$uid" = "$expected" ]; then
            cp "$file" "${WORKDIR}/received.dcm" || return 1
            found=$((found + 1))
        fi
    done < "${WORKDIR}/archive-files"
    [ "$found" -eq 1 ] || return 1
    ts=$(dcmdump -Un +P 0002,0010 "${WORKDIR}/received.dcm" \
        | sed -nE 's/.*\[([0-9.]+)\].*/\1/p') || return 1
    [ "$ts" = "${COMPRESSED_UID}" ]
}

move_compressed() {
    local uid study series receiver received ts
    IFS=$'\t' read -r uid study series _ < "${WORKDIR}/original.tsv"
    receiver=$(receiver_storage_dir)
    receiver_cleanup_storage "$receiver" || return 1
    timeout 30 movescu -v -S -to 5 -ta 10 -td 20 \
        -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${STORESCP_AE_TITLE:-STORE_SCP}" \
        "${PACS_HOST}" "${PACS_PORT}" -k QueryRetrieveLevel=IMAGE \
        -k "StudyInstanceUID=$study" -k "SeriesInstanceUID=$series" -k "SOPInstanceUID=$uid" \
        > "${WORKDIR}/move.log" 2>&1 || return 1
    grep -Eq '(Final Move Response|Move Response:).*\(Success\)' "${WORKDIR}/move.log" || return 1
    find "$receiver" -type f -name '*.dcm' -print > "${WORKDIR}/received-files" || return 1
    [ "$(wc -l < "${WORKDIR}/received-files")" -eq 1 ] || return 1
    read -r received < "${WORKDIR}/received-files"
    cp "$received" "${WORKDIR}/received.dcm" || return 1
    ts=$(dcmdump -Un +P 0002,0010 "${WORKDIR}/received.dcm" \
        | sed -nE 's/.*\[([0-9.]+)\].*/\1/p') || return 1
    [ "$ts" = "${COMPRESSED_UID}" ]
}

compare_decoded() {
    timeout 30 "${DECODER}" "${WORKDIR}/received.dcm" "${WORKDIR}/decoded/object.dcm" \
        > "${WORKDIR}/decode.log" 2>&1 || return 1
    dicom_manifest "${WORKDIR}/decoded.tsv" "${WORKDIR}/decoded" || return 1
    diff -u "${WORKDIR}/original.tsv" "${WORKDIR}/decoded.tsv"
}

run_compressed_case() {
    case "${DICOM_TRANSFER_SYNTAX}" in
        jpeg-lossless)
            COMPRESSOR=(dcmcjpeg +e1); DECODER=dcmdjpeg
            PROPOSE_FLAG=-xs; COMPRESSED_UID=1.2.840.10008.1.2.4.70 ;;
        jpeg-ls-lossless)
            COMPRESSOR=(dcmcjpls +el); DECODER=dcmdjpls
            PROPOSE_FLAG=-xt; COMPRESSED_UID=1.2.840.10008.1.2.4.80 ;;
        rle-lossless)
            COMPRESSOR=(dcmcrle); DECODER=dcmdrle
            PROPOSE_FLAG=-xr; COMPRESSED_UID=1.2.840.10008.1.2.5 ;;
        *) print_fail "Unknown DICOM_TRANSFER_SYNTAX: ${DICOM_TRANSFER_SYNTAX}"; TEST_FAILED=$((TEST_FAILED + 1)); return 1 ;;
    esac
    run_test "${DICOM_TRANSFER_SYNTAX} encode while preserving SOP UID" "Transfer Syntax" compress_source || return 1
    assert_transfer_syntax_uid "${DICOM_TRANSFER_SYNTAX}" "${WORKDIR}/compressed.dcm" "${COMPRESSED_UID}" || return 1
    RESTORE_NEEDED=true
    run_test "${DICOM_TRANSFER_SYNTAX} negotiated C-STORE succeeds" "Transfer Syntax" store_compressed || return 1
    run_test "${DICOM_TRANSFER_SYNTAX} PACS stores exactly one instance in compressed syntax" "Transfer Syntax" stored_compressed || return 1
    if [ "${DICOM_MOVE_TRANSFER_SYNTAX:-uncompressed}" = "${DICOM_TRANSFER_SYNTAX}" ]; then
        run_test "${DICOM_TRANSFER_SYNTAX} C-MOVE preserves compressed syntax" "Transfer Syntax" move_compressed || return 1
    else
        print_skip 'Compressed C-MOVE needs a matching DICOM_MOVE_TRANSFER_SYNTAX; checking stored content here'
    fi
    run_test "${DICOM_TRANSFER_SYNTAX} decoded UID/metadata/full PixelData match" "Transfer Syntax" compare_decoded
}
