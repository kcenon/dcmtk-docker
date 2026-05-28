#!/bin/bash

# Shared PixelData profile defaults for generator and tests.
# The caller may override per-modality dimensions with {CT,MR,CR}_PIXEL_ROWS
# and {CT,MR,CR}_PIXEL_COLS after selecting PIXEL_DATA_PROFILE.

resolve_pixel_data_profile_defaults() {
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
            echo "[pixel-data-profile] WARNING: unknown PIXEL_DATA_PROFILE='${PIXEL_DATA_PROFILE}', falling back to conservative" >&2
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
}
