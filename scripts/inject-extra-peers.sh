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
# For each well-formed entry a HostTable line `name = (AE, host, port)` is
# inserted before the `all_peers` line (so the symbolic name is defined before
# all_peers references it) and the name is appended to the `all_peers` whitelist,
# so the destination works in both the default (ANY) and restricted (all_peers)
# AETable modes. The all_peers match also accepts an indented line (e.g. the
# production example). If the config has no `all_peers` line, entries are
# inserted before `HostTable END` instead. Malformed entries (not exactly
# name=AE:host:port, an empty field, or a non-numeric port) are skipped with a
# warning rather than corrupting the config. awk is used (not sed) so the
# behavior is identical on the Linux container and a macOS host.

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
    valid = 0
    names = ""
    for (i = 1; i <= n; i++) {
        if (arr[i] == "") continue
        # Require exactly "name=AE:host:port" with non-empty fields.
        if (split(arr[i], kv, "=") != 2 || kv[1] == "" || kv[2] == "") {
            print "inject-extra-peers: skipping malformed peer (need name=AE:host:port): " arr[i] > "/dev/stderr"
            continue
        }
        if (split(kv[2], hp, ":") != 3 || hp[1] == "" || hp[2] == "" || hp[3] == "") {
            print "inject-extra-peers: skipping malformed peer (need AE:host:port): " arr[i] > "/dev/stderr"
            continue
        }
        if (hp[3] !~ /^[0-9]+$/) {
            print "inject-extra-peers: skipping peer with non-numeric port: " arr[i] > "/dev/stderr"
            continue
        }
        valid++
        entries[valid] = kv[1] " = (" hp[1] ", " hp[2] ", " hp[3] ")"
        names = names ", " kv[1]
    }
}
# Preferred anchor: emit entries before all_peers and extend the whitelist.
# Matches an indented all_peers line too (e.g. the production example).
/^[[:space:]]*all_peers[[:space:]]*=/ {
    for (i = 1; i <= valid; i++) print entries[i]
    print $0 names
    injected = 1
    next
}
# Fallback: no all_peers line -> define the peers before HostTable END.
/^[[:space:]]*HostTable[[:space:]]+END/ {
    if (!injected) {
        for (i = 1; i <= valid; i++) print entries[i]
        injected = 1
    }
    print
    next
}
{ print }
END {
    if (valid > 0 && !injected) {
        print "inject-extra-peers: WARNING: no all_peers or HostTable END anchor in " FILENAME "; " valid " peer(s) not injected" > "/dev/stderr"
    }
}
' "${CFG}" > "${CFG}.new"

mv "${CFG}.new" "${CFG}"
