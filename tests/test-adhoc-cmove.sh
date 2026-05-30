#!/bin/bash
set -euo pipefail

# Ad-hoc C-MOVE End-to-End Test
# Retrieves a study to a destination that exists ONLY because it was registered
# via EXTRA_PEERS (it is not in the static HostTable). A successful delivery
# proves the inject-extra-peers.sh path works end-to-end, converting the former
# "host-verified in the PR" claim into a repeatable, in-repo gate (issue #62).
#
# Run with the ad-hoc destination configured (see the test-adhoc-cmove CI job):
#   EXTRA_PEERS=adhoc=ADHOC_SCP:storescp-receiver:11112  (in .env, at PACS start)
#   ADHOC_DEST_AE=ADHOC_SCP                               (passed to this script)
# Without ADHOC_DEST_AE the suite skips cleanly so it is safe in test-all.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# ── Configuration ─────────────────────────────────────
PACS_HOST="${PACS_HOST:-pacs-server}"
PACS_PORT="${PACS_PORT:-11112}"
PACS_AE="${PACS_AE_TITLE:-DCMTK_PACS}"
MY_AE="${AE_TITLE:-TEST_SCU}"
STORESCP_HOST="${STORESCP_HOST:-storescp-receiver}"
TEST_DATA_DIR="${TEST_DATA_DIR:-/dicom/testdata}"
# Destination AE that must be registered only via EXTRA_PEERS, not the static
# HostTable. Empty -> skip (default test-all.sh run).
ADHOC_DEST_AE="${ADHOC_DEST_AE:-}"
RECEIVER_STORAGE_DIR="$(receiver_storage_dir)"
MOVE_SETTLE_SECONDS="${MOVE_SETTLE_SECONDS:-2}"

print_header "Ad-hoc C-MOVE End-to-End Test"

# ── Skip path: no ad-hoc destination configured ───────
if [ -z "${ADHOC_DEST_AE}" ]; then
    print_skip "Ad-hoc C-MOVE: ADHOC_DEST_AE not set (run with EXTRA_PEERS + ADHOC_DEST_AE; see the test-adhoc-cmove CI job)"
    print_summary "Ad-hoc C-MOVE E2E"
    exit 0
fi

# ── Preamble: source PACS and the ad-hoc destination reachable ─────
ensure_scp_reachable "source PACS"  "${PACS_HOST}"     "${PACS_PORT}" "${PACS_AE}"        "${MY_AE}" || exit 1
ensure_scp_reachable "ad-hoc dest"  "${STORESCP_HOST}" "${PACS_PORT}" "${ADHOC_DEST_AE}"  "${MY_AE}" || exit 1

# ── Ensure PACS has data to retrieve ──────────────────
ensure_pacs_data "${PACS_HOST}" "${PACS_PORT}" "${PACS_AE}" "${MY_AE}" "${TEST_DATA_DIR}"

# ── Test: C-MOVE the CT study to the EXTRA_PEERS-only destination ──
CT_STUDY_UID="${MANIFEST_CT_STUDY_UID}"
CT_EXPECTED="${MANIFEST_CT_COUNT}"
receiver_cleanup_storage "${RECEIVER_STORAGE_DIR}" || exit 1
run_test "C-MOVE CT study to ad-hoc destination ${ADHOC_DEST_AE} (EXTRA_PEERS-only)" "C-MOVE" \
    movescu -aet "${MY_AE}" -aec "${PACS_AE}" -aem "${ADHOC_DEST_AE}" \
        -S "${PACS_HOST}" "${PACS_PORT}" \
        -k QueryRetrieveLevel=STUDY \
        -k StudyInstanceUID="${CT_STUDY_UID}" || true
sleep "${MOVE_SETTLE_SECONDS}"
verify_move_count "ad-hoc destination received the CT study" "${CT_EXPECTED}" "${RECEIVER_STORAGE_DIR}" || true
verify_move_uids  "ad-hoc destination CT study UIDs"         "${CT_STUDY_UID}" "" "${RECEIVER_STORAGE_DIR}" || true

print_summary "Ad-hoc C-MOVE E2E"
[ "${TEST_FAILED}" -eq 0 ]
