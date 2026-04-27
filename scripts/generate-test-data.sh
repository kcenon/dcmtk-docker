#!/bin/bash
set -e

# Generate synthetic DICOM test data using dump2dcm.
# Usage: generate-test-data.sh [output_dir]
#
# Creates test patients with CT, MR, and CR modalities.
# Uses OID_ROOT env var for UID generation to avoid collision with clinical data.

OUTPUT_DIR="${1:-${TEST_DATA_DIR:-/dicom/testdata}}"
OID_ROOT="${OID_ROOT:-1.2.826.0.1.3680043.8.499}"
GENERATE_PIXEL_DATA="${GENERATE_PIXEL_DATA:-false}"

# PixelData profile selects per-modality default dimensions. Modality-specific
# overrides (e.g. CT_PIXEL_ROWS) win over the profile default.
PIXEL_DATA_PROFILE="${PIXEL_DATA_PROFILE:-conservative}"
case "${PIXEL_DATA_PROFILE}" in
    realistic)
        DEFAULT_CT_ROWS=512;  DEFAULT_CT_COLS=512
        DEFAULT_MR_ROWS=256;  DEFAULT_MR_COLS=256
        DEFAULT_CR_ROWS=1024; DEFAULT_CR_COLS=1024
        ;;
    conservative)
        DEFAULT_CT_ROWS=128;  DEFAULT_CT_COLS=128
        DEFAULT_MR_ROWS=128;  DEFAULT_MR_COLS=128
        DEFAULT_CR_ROWS=224;  DEFAULT_CR_COLS=224
        ;;
    *)
        echo "[generate-test-data] WARNING: unknown PIXEL_DATA_PROFILE='${PIXEL_DATA_PROFILE}', falling back to conservative" >&2
        DEFAULT_CT_ROWS=128;  DEFAULT_CT_COLS=128
        DEFAULT_MR_ROWS=128;  DEFAULT_MR_COLS=128
        DEFAULT_CR_ROWS=224;  DEFAULT_CR_COLS=224
        PIXEL_DATA_PROFILE="conservative"
        ;;
esac

CT_PIXEL_ROWS="${CT_PIXEL_ROWS:-${DEFAULT_CT_ROWS}}"
CT_PIXEL_COLS="${CT_PIXEL_COLS:-${DEFAULT_CT_COLS}}"
MR_PIXEL_ROWS="${MR_PIXEL_ROWS:-${DEFAULT_MR_ROWS}}"
MR_PIXEL_COLS="${MR_PIXEL_COLS:-${DEFAULT_MR_COLS}}"
CR_PIXEL_ROWS="${CR_PIXEL_ROWS:-${DEFAULT_CR_ROWS}}"
CR_PIXEL_COLS="${CR_PIXEL_COLS:-${DEFAULT_CR_COLS}}"

# The legacy uniform PIXEL_DATA_ROWS / PIXEL_DATA_COLS introduced by PR #10
# would silently revert per-modality dimensions to a single shared value, so
# they are deprecated and ignored. Warn loudly if the operator still sets them.
if [ -n "${PIXEL_DATA_ROWS:-}" ] || [ -n "${PIXEL_DATA_COLS:-}" ]; then
    echo "[generate-test-data] WARNING: PIXEL_DATA_ROWS / PIXEL_DATA_COLS are deprecated and ignored." >&2
    echo "[generate-test-data]          Use {CT,MR,CR}_PIXEL_ROWS / _COLS or PIXEL_DATA_PROFILE instead." >&2
fi

# Skip if test data already exists
if [ -d "${OUTPUT_DIR}" ] && [ "$(find "${OUTPUT_DIR}" -name '*.dcm' 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "[generate-test-data] Test data already exists in ${OUTPUT_DIR}, skipping."
    exit 0
fi

mkdir -p "${OUTPUT_DIR}/ct" "${OUTPUT_DIR}/mr" "${OUTPUT_DIR}/cr"

echo "[generate-test-data] Generating synthetic DICOM files..."
echo "[generate-test-data] OID root: ${OID_ROOT}"
echo "[generate-test-data] Output: ${OUTPUT_DIR}"
if [ "${GENERATE_PIXEL_DATA}" = "true" ]; then
    echo "[generate-test-data] PixelData: profile=${PIXEL_DATA_PROFILE}, CT ${CT_PIXEL_ROWS}x${CT_PIXEL_COLS}, MR ${MR_PIXEL_ROWS}x${MR_PIXEL_COLS}, CR ${CR_PIXEL_ROWS}x${CR_PIXEL_COLS}"
else
    echo "[generate-test-data] PixelData: disabled (set GENERATE_PIXEL_DATA=true to enable)"
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

# ── Helper: write a deterministic 16-bit MONOCHROME2 pixel buffer ─────
# A horizontal gradient (constant per column, smooth 0..65535 across cols)
# is generated once per (rows, cols) and cached in TMPDIR for reuse.
# Output: little-endian uint16 raw bytes, total = rows * cols * 2.
# Args: rows cols outfile
generate_pixel_data_file() {
    local rows="$1"
    local cols="$2"
    local outfile="$3"

    local row_seq=""
    local x val lo hi
    for ((x = 0; x < cols; x++)); do
        if [ "${cols}" -gt 1 ]; then
            val=$(( x * 65535 / (cols - 1) ))
        else
            val=0
        fi
        lo=$(( val & 0xFF ))
        hi=$(( (val >> 8) & 0xFF ))
        row_seq+=$(printf '\\x%02x\\x%02x' "${lo}" "${hi}")
    done

    local full_seq=""
    local y
    for ((y = 0; y < rows; y++)); do
        full_seq+="${row_seq}"
    done

    # Single binary write via printf %b (no xxd / perl dependency required)
    printf '%b' "${full_seq}" > "${outfile}"
}

# ── Helper: encode a 16-bit value as a "\\xLO\\xHI" little-endian hex token
# Used by per-modality buffer generators to pre-encode unique values once so
# the per-pixel inner loop can do pure bash string concatenation.
encode_u16_le_hex() {
    local val="$1"
    printf '\\x%02x\\x%02x' "$(( val & 0xFF ))" "$(( (val >> 8) & 0xFF ))"
}

# ── Helper: encode an int16 (two's-complement) as little-endian hex ──
encode_i16_le_hex() {
    local val="$1"
    if [ "$val" -lt 0 ]; then
        val=$(( 65536 + val ))
    fi
    encode_u16_le_hex "$val"
}

# ── CT 7-band signed Hounsfield Unit pattern ────────
# Vertical bands of HU values from air to bone. Two's-complement int16 encoding.
# Pattern: air(-1000) -> fat(-100) -> soft(40) -> muscle(60) -> liver(100)
#          -> contrast(600) -> bone(1000). One-band-per-column-range, identical
# row-to-row, so the row sequence is built once and repeated.
generate_ct_buffer() {
    local rows="$1" cols="$2" outfile="$3"
    local hu_values=(-1000 -100 40 60 100 600 1000)
    local n_bands=${#hu_values[@]}

    local -a band_hex
    local i
    for ((i = 0; i < n_bands; i++)); do
        band_hex[i]=$(encode_i16_le_hex "${hu_values[i]}")
    done

    local row_seq="" x band
    for ((x = 0; x < cols; x++)); do
        band=$(( x * n_bands / cols ))
        [ "$band" -ge "$n_bands" ] && band=$((n_bands - 1))
        row_seq+="${band_hex[band]}"
    done

    local full_seq="" y
    for ((y = 0; y < rows; y++)); do
        full_seq+="${row_seq}"
    done

    printf '%b' "${full_seq}" > "${outfile}"
}

# ── MR 4-band intensity pattern (12-bit unsigned) ────
# CSF(256) -> gray-matter(1024) -> white-matter(2400) -> fat(3800).
# 1D pattern, same per-row build-and-repeat strategy as CT.
generate_mr_buffer() {
    local rows="$1" cols="$2" outfile="$3"
    local mr_values=(256 1024 2400 3800)
    local n_bands=${#mr_values[@]}

    local -a band_hex
    local i
    for ((i = 0; i < n_bands; i++)); do
        band_hex[i]=$(encode_u16_le_hex "${mr_values[i]}")
    done

    local row_seq="" x band
    for ((x = 0; x < cols; x++)); do
        band=$(( x * n_bands / cols ))
        [ "$band" -ge "$n_bands" ] && band=$((n_bands - 1))
        row_seq+="${band_hex[band]}"
    done

    local full_seq="" y
    for ((y = 0; y < rows; y++)); do
        full_seq+="${row_seq}"
    done

    printf '%b' "${full_seq}" > "${outfile}"
}

# ── CR chest-silhouette pattern (14-bit unsigned, 2D) ─
# Background ellipse silhouette with two narrow lung-field stripes and a
# central spine stripe. Inner loop is pure bash concat over a 4-entry hex
# lookup so a 224x224 CR buffer stays under ~500 ms on a typical CI runner.
# Escape hatch: switch to perl-base if this becomes a CI bottleneck (the
# slim image already has perl-base available — see #13 Performance section).
generate_cr_buffer() {
    local rows="$1" cols="$2" outfile="$3"
    local v_bg=500 v_thorax=8000 v_lung=1500 v_spine=15000

    local hex_bg hex_thorax hex_lung hex_spine
    hex_bg=$(encode_u16_le_hex "$v_bg")
    hex_thorax=$(encode_u16_le_hex "$v_thorax")
    hex_lung=$(encode_u16_le_hex "$v_lung")
    hex_spine=$(encode_u16_le_hex "$v_spine")

    local cx=$(( cols / 2 ))
    local cy=$(( rows / 2 ))
    local rx=$(( (cols * 2) / 5 ))
    local ry=$(( (rows * 9) / 20 ))
    [ "$rx" -lt 1 ] && rx=1
    [ "$ry" -lt 1 ] && ry=1
    local rx_sq=$(( rx * rx ))
    local ry_sq=$(( ry * ry ))

    local lung_l=$(( cols * 30 / 100 ))
    local lung_r=$(( cols * 70 / 100 ))
    local lung_hw=$(( cols / 50 ))
    [ "$lung_hw" -lt 1 ] && lung_hw=1

    local spine_hw=$(( cols / 100 ))
    [ "$spine_hw" -lt 1 ] && spine_hw=1

    local full_seq="" y x dy dy_sq term dx dx_sq
    for ((y = 0; y < rows; y++)); do
        dy=$(( y - cy ))
        dy_sq=$(( dy * dy ))
        if [ "$dy_sq" -ge "$ry_sq" ]; then
            term=-1
        else
            term=$(( rx_sq - (dy_sq * rx_sq) / ry_sq ))
        fi

        for ((x = 0; x < cols; x++)); do
            # Spine stripe overrides everything (full-height central column).
            if (( x >= cx - spine_hw && x <= cx + spine_hw )); then
                full_seq+="${hex_spine}"
                continue
            fi

            dx=$(( x - cx ))
            dx_sq=$(( dx * dx ))

            if (( term >= 0 )) && (( dx_sq <= term )); then
                if (( (x >= lung_l - lung_hw && x <= lung_l + lung_hw) || \
                      (x >= lung_r - lung_hw && x <= lung_r + lung_hw) )); then
                    full_seq+="${hex_lung}"
                else
                    full_seq+="${hex_thorax}"
                fi
            else
                full_seq+="${hex_bg}"
            fi
        done
    done

    printf '%b' "${full_seq}" > "${outfile}"
}

# ── Helper: create a DICOM file from attributes ─────
# Args: output_file sop_class_uid sop_instance_uid patient_name patient_id
#       patient_sex study_uid study_date accession modality study_id study_desc
#       series_uid series_number series_desc instance_number
create_dicom() {
    local output_file="$1"
    local sop_class_uid="$2"
    local sop_instance_uid="$3"
    local patient_name="$4"
    local patient_id="$5"
    local patient_sex="$6"
    local study_uid="$7"
    local study_date="$8"
    local accession="$9"
    local modality="${10}"
    local study_id="${11}"
    local study_desc="${12}"
    local series_uid="${13}"
    local series_number="${14}"
    local series_desc="${15}"
    local instance_number="${16}"

    local dump_file="${TMPDIR}/$(basename "${output_file}" .dcm).txt"

    cat > "${dump_file}" << DUMP
# DICOM dump file - generated by generate-test-data.sh

# File Meta Information
(0002,0001) OB 00\\01
(0002,0002) UI =${sop_class_uid}
(0002,0003) UI [${sop_instance_uid}]
(0002,0010) UI =LittleEndianExplicit

# Patient Module
(0010,0010) PN [${patient_name}]
(0010,0020) LO [${patient_id}]
(0010,0040) CS [${patient_sex}]

# General Study Module
(0008,0020) DA [${study_date}]
(0008,0030) TM [120000]
(0008,0050) SH [${accession}]
(0008,1030) LO [${study_desc}]
(0020,000D) UI [${study_uid}]
(0020,0010) SH [${study_id}]

# General Series Module
(0008,0060) CS [${modality}]
(0008,103E) LO [${series_desc}]
(0020,000E) UI [${series_uid}]
(0020,0011) IS [${series_number}]

# General Image Module
(0020,0013) IS [${instance_number}]

# SOP Common Module
(0008,0016) UI =${sop_class_uid}
(0008,0018) UI [${sop_instance_uid}]
DUMP

    if [ "${GENERATE_PIXEL_DATA}" = "true" ]; then
        # Resolve per-modality dimensions, attribute values, and the buffer
        # generator from the profile/override matrix configured at script start.
        # The PIXEL_EXPECTED table in tests/test-pixeldata.sh is the single
        # source of truth that mirrors these per-modality values.
        local mod_lc="${modality,,}"
        local rows cols bits_stored high_bit pix_rep extras
        case "${mod_lc}" in
            ct)
                rows="${CT_PIXEL_ROWS}"; cols="${CT_PIXEL_COLS}"
                bits_stored=16; high_bit=15; pix_rep=1
                # CT (PS3.3 C.8.2.1): Rescale tags map stored values to HU,
                # plus a soft-tissue display window (W/L 400/40).
                extras=$'\n(0028,1052) DS [-1024]\n(0028,1053) DS [1.0]\n(0028,1054) LO [HU]\n(0028,1050) DS [40]\n(0028,1051) DS [400]'
                ;;
            mr)
                rows="${MR_PIXEL_ROWS}"; cols="${MR_PIXEL_COLS}"
                bits_stored=12; high_bit=11; pix_rep=0
                # MR (PS3.3 C.8.3.1): intensity-based window, no Rescale tags.
                extras=$'\n(0028,1050) DS [2048]\n(0028,1051) DS [4096]'
                ;;
            cr)
                rows="${CR_PIXEL_ROWS}"; cols="${CR_PIXEL_COLS}"
                bits_stored=14; high_bit=13; pix_rep=0
                # CR (PS3.3 C.8.1.2): wide window plus identity presentation LUT.
                extras=$'\n(0028,1050) DS [8192]\n(0028,1051) DS [16383]\n(2050,0020) CS [IDENTITY]'
                ;;
            *)
                # Unknown modality: fall back to the legacy uniform 16-bit
                # unsigned gradient, sized to CT defaults.
                rows="${CT_PIXEL_ROWS}"; cols="${CT_PIXEL_COLS}"
                bits_stored=16; high_bit=15; pix_rep=0; extras=""
                ;;
        esac

        # Per-modality cache key prevents cross-modality buffer collisions.
        local pixel_file="${TMPDIR}/pixels_${mod_lc}_${rows}x${cols}.bin"
        if [ ! -s "${pixel_file}" ]; then
            case "${mod_lc}" in
                ct) generate_ct_buffer "${rows}" "${cols}" "${pixel_file}" ;;
                mr) generate_mr_buffer "${rows}" "${cols}" "${pixel_file}" ;;
                cr) generate_cr_buffer "${rows}" "${cols}" "${pixel_file}" ;;
                *)  generate_pixel_data_file "${rows}" "${cols}" "${pixel_file}" ;;
            esac
        fi

        cat >> "${dump_file}" << PIXDUMP

# Image Pixel Module
(0028,0002) US 1
(0028,0004) CS [MONOCHROME2]
(0028,0010) US ${rows}
(0028,0011) US ${cols}
(0028,0100) US 16
(0028,0101) US ${bits_stored}
(0028,0102) US ${high_bit}
(0028,0103) US ${pix_rep}${extras}
(7FE0,0010) OW =${pixel_file}
PIXDUMP
    fi

    dump2dcm "${dump_file}" "${output_file}" 2>/dev/null
}

# ── Patient 1: DOE^JOHN - CT (5 slices) ─────────────
echo "[generate-test-data] Creating Patient 1: DOE^JOHN (CT, 5 instances)"

STUDY_UID="${OID_ROOT}.1.1"
SERIES_UID="${OID_ROOT}.1.1.1"

for i in $(seq 1 5); do
    SOP_UID="${OID_ROOT}.1.1.1.${i}"
    create_dicom \
        "${OUTPUT_DIR}/ct/ct_pat001_${i}.dcm" \
        "CTImageStorage" \
        "${SOP_UID}" \
        "DOE^JOHN" \
        "PAT001" \
        "M" \
        "${STUDY_UID}" \
        "20240115" \
        "ACC001" \
        "CT" \
        "STUDY001" \
        "CT Abdomen" \
        "${SERIES_UID}" \
        "1" \
        "Axial 5mm" \
        "${i}"
done

# ── Patient 2: SMITH^JANE - MR (2 series x 3) ──────
echo "[generate-test-data] Creating Patient 2: SMITH^JANE (MR, 6 instances)"

STUDY_UID="${OID_ROOT}.2.1"

# Series 1: T1
SERIES_UID="${OID_ROOT}.2.1.1"
for i in $(seq 1 3); do
    SOP_UID="${OID_ROOT}.2.1.1.${i}"
    create_dicom \
        "${OUTPUT_DIR}/mr/mr_pat002_s1_${i}.dcm" \
        "MRImageStorage" \
        "${SOP_UID}" \
        "SMITH^JANE" \
        "PAT002" \
        "F" \
        "${STUDY_UID}" \
        "20240220" \
        "ACC002" \
        "MR" \
        "STUDY002" \
        "MR Brain" \
        "${SERIES_UID}" \
        "1" \
        "T1 Axial" \
        "${i}"
done

# Series 2: T2
SERIES_UID="${OID_ROOT}.2.1.2"
for i in $(seq 1 3); do
    SOP_UID="${OID_ROOT}.2.1.2.${i}"
    create_dicom \
        "${OUTPUT_DIR}/mr/mr_pat002_s2_${i}.dcm" \
        "MRImageStorage" \
        "${SOP_UID}" \
        "SMITH^JANE" \
        "PAT002" \
        "F" \
        "${STUDY_UID}" \
        "20240220" \
        "ACC002" \
        "MR" \
        "STUDY002" \
        "MR Brain" \
        "${SERIES_UID}" \
        "2" \
        "T2 Axial" \
        "${i}"
done

# ── Patient 3: WANG^LEI - CR (2 images) ─────────────
echo "[generate-test-data] Creating Patient 3: WANG^LEI (CR, 2 instances)"

STUDY_UID="${OID_ROOT}.3.1"
SERIES_UID="${OID_ROOT}.3.1.1"

for i in $(seq 1 2); do
    SOP_UID="${OID_ROOT}.3.1.1.${i}"
    create_dicom \
        "${OUTPUT_DIR}/cr/cr_pat003_${i}.dcm" \
        "ComputedRadiographyImageStorage" \
        "${SOP_UID}" \
        "WANG^LEI" \
        "PAT003" \
        "M" \
        "${STUDY_UID}" \
        "20240310" \
        "ACC003" \
        "CR" \
        "STUDY003" \
        "Chest PA" \
        "${SERIES_UID}" \
        "1" \
        "Chest" \
        "${i}"
done

# ── Summary ──────────────────────────────────────────
TOTAL=$(find "${OUTPUT_DIR}" -name "*.dcm" | wc -l)
echo "[generate-test-data] Generation complete: ${TOTAL} DICOM files"
echo "[generate-test-data] CT: $(find "${OUTPUT_DIR}/ct" -name "*.dcm" | wc -l) files"
echo "[generate-test-data] MR: $(find "${OUTPUT_DIR}/mr" -name "*.dcm" | wc -l) files"
echo "[generate-test-data] CR: $(find "${OUTPUT_DIR}/cr" -name "*.dcm" | wc -l) files"
