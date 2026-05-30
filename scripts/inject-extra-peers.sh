#!/bin/bash
set -euo pipefail

# Inject ad-hoc C-MOVE peers into a rendered dcmqrscp config.
#
# dcmqrscp resolves C-MOVE destinations from a static HostTable, so a retrieval
# to an AE Title that is not pre-registered fails. This script lets the operator
# register extra destinations at container start (or via `pacs.sh add-peer`)
# without editing the template or rebuilding the image.
#
# Usage: inject-extra-peers.sh <rendered_config_file>
#   EXTRA_PEERS="name=AE:host:port name2=AE2:host2:port2"   (space-separated)
#
# For each entry a HostTable line `name = (AE, host, port)` is inserted before
# `HostTable END`, and the symbolic name is appended to the `all_peers` whitelist
# so the destination works in both the default (ANY) and restricted (all_peers)
# AETable modes. awk is used (not sed) so the behavior is identical on the Linux
# container and a macOS host.

CFG="${1:?usage: inject-extra-peers.sh <config_file>}"

# Nothing to do when no extra peers are configured.
if [ -z "${EXTRA_PEERS:-}" ]; then
    exit 0
fi

if [ ! -f "${CFG}" ]; then
    echo "inject-extra-peers: config file not found: ${CFG}" >&2
    exit 1
fi

awk -v peers="${EXTRA_PEERS}" '
BEGIN {
    n = split(peers, arr, " ")
    names = ""
    for (i = 1; i <= n; i++) {
        if (arr[i] == "") continue
        split(arr[i], kv, "=")          # kv[1]=name, kv[2]=AE:host:port
        split(kv[2], hp, ":")           # hp[1]=AE, hp[2]=host, hp[3]=port
        entries[i] = kv[1] " = (" hp[1] ", " hp[2] ", " hp[3] ")"
        names = names ", " kv[1]
    }
}
/^all_peers = / {
    # Emit the ad-hoc HostTable entries BEFORE the all_peers line so their
    # symbolic names are defined before all_peers references them.
    for (i = 1; i <= n; i++) {
        if (entries[i] != "") print entries[i]
    }
    print $0 names
    next
}
{ print }
' "${CFG}" > "${CFG}.new"

mv "${CFG}.new" "${CFG}"
