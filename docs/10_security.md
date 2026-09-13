# Security Notes

Part of the dcmtk-docker documentation; start from the [README](../README.md).

**The default configuration shipped in this repository is intended for
isolated test environments only and is NOT safe for production use.**

## Default behavior: `ANY` Peers

Both `config/dcmqrscp-primary.cfg.template` and
`config/dcmqrscp-secondary.cfg.template` set the AETable Peers field to
`ANY`:

```
AETable BEGIN
  ${AE_TITLE}  ${STORAGE_DIR}/${AE_TITLE}  RW  (...)  ANY
AETable END
```

`ANY` instructs `dcmqrscp` to accept associations from **any** DICOM SCU
on the network without verifying the Calling AE Title. This is convenient
for local integration testing but exposes the PACS to:

- Unauthenticated C-STORE from arbitrary peers (data poisoning, malware
  delivery via DICOM payloads).
- Unauthenticated C-FIND / C-MOVE that may exfiltrate PHI (Protected
  Health Information).

## Peer whitelist alternative

For any deployment that touches a non-isolated network, replace `ANY`
with a `HostTable` + `all_peers` whitelist that names exactly which AE
Titles are allowed to connect. A complete, annotated example is provided
at:

```
config/dcmqrscp-production.cfg.example
```

That file:

1. Lists each modality / viewer / archive explicitly in `HostTable`.
2. Aggregates them under a symbolic name (`all_peers`).
3. References that name in the `AETable` Peers field instead of `ANY`.

## Additional hardening

Even with a peer whitelist, a production deployment should add:

- **Network isolation**: Run `dcmqrscp` behind a firewall or on a private
  VLAN. DICOM is not encrypted by default.
- **TLS**: `dcmqrscp` has TLS options (`--enable-tls`) only from DCMTK
  3.6.9, and this image has DCMTK 3.6.7. Protect data in transit with a
  TLS-terminating proxy in front of it, or run DCMTK 3.6.9 or later. In
  3.6.9, TLS covers incoming associations (storage, query, and C-GET) but
  not the outgoing C-MOVE sub-associations; DCMTK 3.7.0 adds those.
- **Audit logging**: Set `LOG_LEVEL=info` (or `debug` during incident
  triage) and forward `dcmqrscp` logs to a central log store. Alert on
  rejected associations.
- **Access reviews**: Periodically audit the HostTable; remove
  decommissioned peers and rotate AE Titles when needed.

## Restricting the published bind address

By default every published DICOM port binds to all host interfaces
(`0.0.0.0`). Docker programs its own iptables rules for published ports,
which **bypass host-level firewalls such as `ufw`**, so a port published
on `0.0.0.0` is reachable from any network the host can see.

The `PACS_BIND_ADDR` environment variable controls the host interface
the four published ports bind to:

```
ports:
  - "${PACS_BIND_ADDR:-0.0.0.0}:${PACS1_HOST_PORT:-11112}:11112"
```

The default `0.0.0.0` preserves the original behavior (CI and the test
suite reach the services over the Docker network, not host ports, so the
default keeps them green). For any deployment that touches a non-isolated
network, set `PACS_BIND_ADDR` in your `.env` to a single trusted
interface — typically loopback — and reach the stack through a reverse
proxy or SSH tunnel:

```bash
# .env: only expose the published ports to the local host
PACS_BIND_ADDR=127.0.0.1
```

Combine this with a firewall and/or a TLS-terminating reverse proxy that
enforces peer identity. Note: a secure-by-default `127.0.0.1` bind is a
behavior change and is intentionally **not** the shipped default; it is
tracked separately.

### Concurrency is bounded at the network boundary, not per-service

`storescp` (`storescp-receiver`) and `wlmscpfs` (`mwl-server`) are
single-process sequential receivers, and DCMTK provides no
concurrent-association cap flag for them — there is no per-service knob
to invent here. Bound their exposure with the network boundary above
(firewall / reverse proxy / restricted `PACS_BIND_ADDR`) rather than a
DCMTK option. `dcmqrscp` does cap concurrency via its existing
`MaxAssociations` setting (`MAX_ASSOCIATIONS`, default 16).

## Restricted AE whitelist profile (opt-in)

For test runs that need to exercise production-like access control
without leaving the repo, the project ships a second pair of dcmqrscp
config templates wired to the `all_peers` whitelist:

| Mode | Template (Primary) | Template (Secondary) | Peers field |
|------|--------------------|----------------------|-------------|
| `test` (default) | `dcmqrscp-primary.cfg.template` | `dcmqrscp-secondary.cfg.template` | `ANY` |
| `restricted` (opt-in) | `dcmqrscp-primary-restricted.cfg.template` | `dcmqrscp-secondary-restricted.cfg.template` | `all_peers` |

The `restricted` profile keeps the same HostTable entries used by the
test suite (`test_client`, `store_scp`, sibling PACS), so the default
test data path still works. Any Calling AE Title outside that list is
rejected at association setup.

### What restricted mode does NOT cover

Restricted mode is **not** a stack-wide authentication switch. It swaps
only the two `dcmqrscp` config templates, so it protects **only the
dcmqrscp query/retrieve entry** (the primary and secondary PACS
servers). The other DICOM-facing services remain unauthenticated in
**every** mode, including restricted:

- **`storescp-receiver`** accepts unauthenticated C-STORE from any peer.
  Its `--aetitle` flag sets the receiver's own Called AE Title; it is
  **not** a Calling-AE whitelist and does not restrict who may connect.
- **`mwl-server`** (`wlmscpfs`) accepts unauthenticated C-FIND from any
  peer and has no Calling-AE access control. A Modality Worklist query
  returns scheduled-procedure and patient demographic data (PHI), so any
  unauthenticated C-FIND can read the worklist.

If you need to restrict these services, place a network boundary in
front of them (firewall, private VLAN, or a TLS-terminating reverse
proxy that enforces peer identity). DCMTK's `storescp` and `wlmscpfs`
do not provide a built-in Calling-AE whitelist.

```bash
# Start the stack in restricted (whitelist) mode
docker compose -f docker-compose.yml -f docker-compose.restricted.yml up -d

# Run the negative tests that assert unknown callers are rejected
docker compose exec test-client bash /tests/test-restricted-mode.sh

# Return to the default (test) mode
docker compose down
docker compose up -d
```

`./pacs.sh up` continues to launch the default `test` mode unchanged;
restricted mode is purely an opt-in compose override (see
`docker-compose.restricted.yml`).
