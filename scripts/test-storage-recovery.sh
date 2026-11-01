#!/usr/bin/env bash
set -euo pipefail
# Host runner for an isolated Compose project with fresh fixture catalogs.
LOG=$(mktemp -t storage-recovery-XXXXXX)
docker compose exec -T test-client bash /tests/test-concurrent-store.sh | tee "${LOG}"
WORK=$(sed -n 's/^Concurrent storage workspace: //p' "${LOG}")
[ -n "${WORK}" ] || exit 1

# Exercise actual transfers between both PACS, with the complete loaded set.
docker compose exec -T test-client bash -s -- "${WORK}" <<'MOVE'
set -euo pipefail
source /tests/test-helpers.sh
source /tests/integrity-helpers.sh
cut -f2 "$1/disjoint.tsv" | sort -u > "$1/recovery-studies"
for direction in forward reverse; do
    host="${PACS_HOST:-pacs-server}"; ae="${PACS_AE_TITLE:-DCMTK_PACS}"
    dest="${PACS2_AE_TITLE:-DCMTK_PAC2}"; port="${PACS_PORT:-11112}"
    if [ "$direction" = reverse ]; then
        host="${PACS2_HOST:-pacs-server-2}"; ae="${PACS2_AE_TITLE:-DCMTK_PAC2}"
        dest="${PACS_AE_TITLE:-DCMTK_PACS}"; port="${PACS2_PORT:-${PACS_PORT:-11112}}"
    fi
    while read -r study; do
        log="$1/recovery-move-$direction-$study.log"
        timeout 60 movescu -v -S -to 5 -ta 10 -td 20 -aet "${AE_TITLE:-TEST_SCU}" \
            -aec "$ae" -aem "$dest" "$host" "$port" \
            -k QueryRetrieveLevel=STUDY -k "StudyInstanceUID=$study" > "$log" 2>&1
        grep -Eq '(Final Move Response|Move Response:).*\(Success\)' "$log"
    done < "$1/recovery-studies"
done
MOVE
verify() {
    docker compose exec -T test-client bash /tests/test-concurrent-store.sh --verify-only "${WORK}"
}
verify
for cycle in 1 2 3; do
    echo "Recovery: restart cycle ${cycle}"
    docker compose restart -t 10 pacs-server pacs-server-2
    docker compose up -d --no-build --wait --wait-timeout 120
    verify
done
docker compose up -d --no-build --force-recreate --wait --wait-timeout 120 pacs-server pacs-server-2
verify
docker compose kill -s SIGKILL pacs-server-2
docker compose up -d --no-build --wait --wait-timeout 120
verify
rm -f "${LOG}"
echo 'PASS: concurrent storage, bidirectional C-MOVE, restart, recreate, and idle SIGKILL recovery'
