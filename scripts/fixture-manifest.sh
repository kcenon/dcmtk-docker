#!/bin/bash
# ============================================================================
# Synthetic test-fixture manifest - SINGLE SOURCE OF TRUTH
# ============================================================================
# Defines the identity of the synthetic CT/MR/CR dataset in ONE place so that
# the producer (scripts/generate-test-data.sh) and the consumers
# (tests/*.sh, via tests/test-helpers.sh) never drift apart.
#
# This file is installed to /usr/local/bin in the image (COPY scripts/), which
# is the only path reachable from BOTH the PACS/test-client containers and the
# host. Source it like:
#   source "$(dirname "$0")/fixture-manifest.sh"      # from scripts/
#   source /usr/local/bin/fixture-manifest.sh         # from /tests
#
# Pointing the suite at a FOREIGN (non-DCMTK) PACS:
#   1. Set OID_ROOT to a value that will not collide with the target's data.
#   2. Seed the target PACS with this dataset (storescu the generated files, or
#      generate-test-data.sh then C-STORE them).
#   3. Run the test scripts unchanged - every assertion reads the UIDs, counts,
#      and demographics from this manifest, so they follow OID_ROOT automatically.
# ============================================================================

# Canonical OID root. An OID_ROOT environment override wins so the whole fixture
# identity can be relocated; otherwise the project default is used. `:=` sets
# the variable when unset/empty so downstream consumers see a concrete value.
: "${OID_ROOT:=1.2.826.0.1.3680043.8.499}"

# Back-compat alias retained for scripts that still reference DEFAULT_OID_ROOT.
DEFAULT_OID_ROOT="1.2.826.0.1.3680043.8.499"

# Effective OID root used to derive every UID below.
MANIFEST_OID_ROOT="${OID_ROOT}"

# ── Study / series UIDs (derived from the OID root) ─────────────────────────
# SOP Instance UIDs are "<series_uid>.<instance_number>", so the test data
# generator only needs the series UID plus a loop index.
MANIFEST_CT_STUDY_UID="${MANIFEST_OID_ROOT}.1.1"
MANIFEST_CT_SERIES_UID="${MANIFEST_OID_ROOT}.1.1.1"

MANIFEST_MR_STUDY_UID="${MANIFEST_OID_ROOT}.2.1"
MANIFEST_MR_T1_SERIES_UID="${MANIFEST_OID_ROOT}.2.1.1"
MANIFEST_MR_T2_SERIES_UID="${MANIFEST_OID_ROOT}.2.1.2"

MANIFEST_CR_STUDY_UID="${MANIFEST_OID_ROOT}.3.1"
MANIFEST_CR_SERIES_UID="${MANIFEST_OID_ROOT}.3.1.1"

# ── Expected counts ─────────────────────────────────────────────────────────
MANIFEST_CT_COUNT=5
MANIFEST_MR_T1_COUNT=3
MANIFEST_MR_T2_COUNT=3
MANIFEST_MR_COUNT=6          # T1 + T2
MANIFEST_CR_COUNT=2
MANIFEST_TOTAL_COUNT=13
MANIFEST_STUDY_COUNT=3
MANIFEST_MR_SERIES_COUNT=2   # PAT002 has T1 + T2

# ── Patient 1: CT ───────────────────────────────────────────────────────────
MANIFEST_CT_PATIENT_NAME="DOE^JOHN"
MANIFEST_CT_PATIENT_ID="PAT001"
MANIFEST_CT_PATIENT_SEX="M"
MANIFEST_CT_STUDY_DATE="20240115"
MANIFEST_CT_ACCESSION="ACC001"
MANIFEST_CT_MODALITY="CT"
MANIFEST_CT_STUDY_ID="STUDY001"
MANIFEST_CT_STUDY_DESC="CT Abdomen"
MANIFEST_CT_SERIES_DESC="Axial 5mm"

# ── Patient 2: MR (T1 + T2 series) ──────────────────────────────────────────
MANIFEST_MR_PATIENT_NAME="SMITH^JANE"
MANIFEST_MR_PATIENT_ID="PAT002"
MANIFEST_MR_PATIENT_SEX="F"
MANIFEST_MR_STUDY_DATE="20240220"
MANIFEST_MR_ACCESSION="ACC002"
MANIFEST_MR_MODALITY="MR"
MANIFEST_MR_STUDY_ID="STUDY002"
MANIFEST_MR_STUDY_DESC="MR Brain"
MANIFEST_MR_T1_SERIES_DESC="T1 Axial"
MANIFEST_MR_T2_SERIES_DESC="T2 Axial"

# ── Patient 3: CR ───────────────────────────────────────────────────────────
MANIFEST_CR_PATIENT_NAME="WANG^LEI"
MANIFEST_CR_PATIENT_ID="PAT003"
MANIFEST_CR_PATIENT_SEX="M"
MANIFEST_CR_STUDY_DATE="20240310"
MANIFEST_CR_ACCESSION="ACC003"
MANIFEST_CR_MODALITY="CR"
MANIFEST_CR_STUDY_ID="STUDY003"
MANIFEST_CR_STUDY_DESC="Chest PA"
MANIFEST_CR_SERIES_DESC="Chest"

# ── Query helpers ───────────────────────────────────────────────────────────
# A study-date range that spans all three studies (for date-range C-FIND).
MANIFEST_STUDY_DATE_RANGE="20240101-20240331"
# Identifiers guaranteed NOT to exist in the dataset, for negative tests.
MANIFEST_NONEXISTENT_PATIENT_ID="NONEXISTENT"
MANIFEST_NONEXISTENT_STUDY_UID="1.2.3.999.999.999"

# ── Modality Worklist (MWL) ─────────────────────────────────────────────────
# The MWL SCP (wlmscpfs) serves scheduled procedure steps that reuse the patient
# identity above, so a modality fetching its worklist sees the same patients it
# will later store images for. AE titles are overridable for foreign-target runs.
MANIFEST_WLM_AE_TITLE="${WLM_AE_TITLE:-DCMTK_WLM}"
MANIFEST_WLM_STATION_AE="${WLM_STATION_AE:-MODALITY01}"
MANIFEST_WLM_STATION_NAME="STATION01"
MANIFEST_WLM_PHYSICIAN="PHYSICIAN^A"
MANIFEST_WLM_START_TIME="120000"
