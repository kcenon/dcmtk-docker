#!/bin/bash
set -euo pipefail

# Ad-hoc C-MOVE Peer Injection Test
# Verifies that scripts/inject-extra-peers.sh injects EXTRA_PEERS into a rendered
# dcmqrscp HostTable correctly: each peer becomes a HostTable entry defined BEFORE
# the all_peers reference, and the symbolic name is appended to all_peers. The
# end-to-end C-MOVE to an injected destination is exercised by the host-side
# verification recorded in the PR; here we test the rendering logic in isolation
# so it cannot regress.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

# Locate the injector: image path first, repo path as a host-run fallback.
INJECT="/usr/local/bin/inject-extra-peers.sh"
[ -x "${INJECT}" ] || INJECT="${SCRIPT_DIR}/../scripts/inject-extra-peers.sh"

make_cfg() {
    cat <<'CFG'
HostTable BEGIN
test_client = (TEST_SCU, test-client, 11112)
store_scp = (STORE_SCP, storescp-receiver, 11112)
all_peers = test_client, store_scp
HostTable END
AETable BEGIN
DCMTK_PACS /dicom/db/DCMTK_PACS RW (200, 1024mb) ANY
AETable END
CFG
}

print_header "Ad-hoc C-MOVE Peer Injection Tests"

# Test 1: a single ad-hoc peer lands in HostTable + all_peers.
TEST_TOTAL=$((TEST_TOTAL + 1))
CFG1=$(mktemp)
make_cfg > "${CFG1}"
EXTRA_PEERS="adhoc=EXT_SCP:ext-host:11114" bash "${INJECT}" "${CFG1}"
if grep -q 'adhoc = (EXT_SCP, ext-host, 11114)' "${CFG1}" \
   && grep -q 'all_peers = test_client, store_scp, adhoc' "${CFG1}"; then
    print_pass "inject: single peer added to HostTable and all_peers"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: single peer not injected correctly"
    TEST_FAILED=$((TEST_FAILED + 1))
fi

# Test 2: the ad-hoc definition must precede the all_peers reference.
TEST_TOTAL=$((TEST_TOTAL + 1))
def_line=$(grep -n '^adhoc = ' "${CFG1}" | head -1 | cut -d: -f1)
ref_line=$(grep -n '^all_peers = ' "${CFG1}" | head -1 | cut -d: -f1)
if [ -n "${def_line}" ] && [ -n "${ref_line}" ] && [ "${def_line}" -lt "${ref_line}" ]; then
    print_pass "inject: ad-hoc definition precedes all_peers reference"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: ad-hoc definition does not precede all_peers (def=${def_line} ref=${ref_line})"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
rm -f "${CFG1}"

# Test 3: multiple peers are all injected.
TEST_TOTAL=$((TEST_TOTAL + 1))
CFG2=$(mktemp)
make_cfg > "${CFG2}"
EXTRA_PEERS="a1=AE1:h1:11114 a2=AE2:h2:11115" bash "${INJECT}" "${CFG2}"
if grep -q 'a1 = (AE1, h1, 11114)' "${CFG2}" \
   && grep -q 'a2 = (AE2, h2, 11115)' "${CFG2}" \
   && grep -q 'all_peers = test_client, store_scp, a1, a2' "${CFG2}"; then
    print_pass "inject: multiple peers added"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: multiple peers not injected correctly"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
rm -f "${CFG2}"

# Test 4: a no-op when EXTRA_PEERS is empty (default).
TEST_TOTAL=$((TEST_TOTAL + 1))
CFG3=$(mktemp); CFG3B=$(mktemp)
make_cfg > "${CFG3}"
cp "${CFG3}" "${CFG3B}"
EXTRA_PEERS="" bash "${INJECT}" "${CFG3}"
if diff -q "${CFG3}" "${CFG3B}" >/dev/null; then
    print_pass "inject: no-op when EXTRA_PEERS is empty"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: config modified despite empty EXTRA_PEERS"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
rm -f "${CFG3}" "${CFG3B}"

# Test 5: malformed entries are skipped (no config corruption); valid ones land.
TEST_TOTAL=$((TEST_TOTAL + 1))
CFG4=$(mktemp)
make_cfg > "${CFG4}"
# bad=ONLYAE (no colon), x=A:h:abc (non-numeric port), good=GOODAE:gh:11116 (valid)
EXTRA_PEERS="bad=ONLYAE x=A:h:abc good=GOODAE:gh:11116" bash "${INJECT}" "${CFG4}" 2>/dev/null
if grep -q 'good = (GOODAE, gh, 11116)' "${CFG4}" \
   && grep -q 'all_peers = test_client, store_scp, good' "${CFG4}" \
   && ! grep -q 'bad' "${CFG4}" \
   && ! grep -q '( , ' "${CFG4}" \
   && ! grep -q ', )' "${CFG4}"; then
    print_pass "inject: malformed peers skipped, valid peer injected, no corruption"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: malformed-peer handling incorrect"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
rm -f "${CFG4}"

# Test 6: an indented all_peers line (production-style) is still matched.
TEST_TOTAL=$((TEST_TOTAL + 1))
CFG5=$(mktemp)
cat > "${CFG5}" <<'CFG'
HostTable BEGIN
  modality_ct1 = (CT1, ct1-host, 104)
  all_peers      = modality_ct1
HostTable END
CFG
EXTRA_PEERS="adhoc=EXT_SCP:ext-host:11114" bash "${INJECT}" "${CFG5}" 2>/dev/null
if grep -q 'adhoc = (EXT_SCP, ext-host, 11114)' "${CFG5}" \
   && grep -Eq 'all_peers[[:space:]]*=.*adhoc' "${CFG5}"; then
    print_pass "inject: indented all_peers line is matched (no silent no-op)"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: indented all_peers not matched (silent no-op)"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
rm -f "${CFG5}"

# Test 7: out-of-range ports are skipped (0, > 65535); the valid peer lands.
TEST_TOTAL=$((TEST_TOTAL + 1))
CFG6=$(mktemp)
make_cfg > "${CFG6}"
# zero=Z:zh:0 (port < 1), big=B:bh:70000 (port > 65535), ok=OKAE:okh:11117 (valid)
EXTRA_PEERS="zero=Z:zh:0 big=B:bh:70000 ok=OKAE:okh:11117" bash "${INJECT}" "${CFG6}" 2>/dev/null
if grep -q 'ok = (OKAE, okh, 11117)' "${CFG6}" \
   && grep -q 'all_peers = test_client, store_scp, ok' "${CFG6}" \
   && ! grep -q 'zero' "${CFG6}" \
   && ! grep -q 'big' "${CFG6}"; then
    print_pass "inject: out-of-range ports skipped, valid peer injected"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: out-of-range port handling incorrect"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
rm -f "${CFG6}"

# Test 8: a duplicate symbolic name is injected once; the duplicate is skipped.
TEST_TOTAL=$((TEST_TOTAL + 1))
CFG7=$(mktemp)
make_cfg > "${CFG7}"
# dup defined twice with different targets; only the first must be injected.
EXTRA_PEERS="dup=AEA:ha:11118 dup=AEB:hb:11119" bash "${INJECT}" "${CFG7}" 2>/dev/null
dup_def_count=$(grep -c '^dup = ' "${CFG7}")
if [ "${dup_def_count}" -eq 1 ] \
   && grep -q 'dup = (AEA, ha, 11118)' "${CFG7}" \
   && ! grep -q 'dup = (AEB, hb, 11119)' "${CFG7}" \
   && grep -q 'all_peers = test_client, store_scp, dup$' "${CFG7}"; then
    print_pass "inject: duplicate name injected once, duplicate skipped"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    print_fail "inject: duplicate-name handling incorrect (dup_def_count=${dup_def_count})"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
rm -f "${CFG7}"

print_summary "Ad-hoc Peers"
[ "${TEST_FAILED}" -eq 0 ]
