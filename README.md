# DCMTK PACS Test Environment

**Status: active** | **Latest release:** [v0.2.0](https://github.com/kcenon/dcmtk-docker/releases/tag/v0.2.0) ([changelog](CHANGELOG.md))

A Docker-based PACS integration test environment using DCMTK.
`./pacs.sh up` starts two query/retrieve PACS servers, a C-STORE receiver, a
Modality Worklist server, and a client container with the DCMTK command-line
tools on one Docker network.

## Quick Start

```bash
# 1. Start all services (auto-configures .env if needed)
./pacs.sh up

# 2. Run the full test suite
./pacs.sh test

# 3. Check service status
./pacs.sh status
```

`./pacs.sh test` runs `tests/test-all.sh`: the C-ECHO, C-STORE, C-FIND, C-MOVE,
Modality Worklist, ad-hoc peer, transfer-syntax, and load-smoke suites. The
PixelData, ad-hoc C-MOVE delivery, and TLS suites skip unless their settings
are enabled.

> **Note:** `.env` is optional. `docker-compose.yml` uses
> `${VAR:-default}` interpolation, so every variable has a built-in fallback
> even when `.env` is absent. `env.default` is a template that `./pacs.sh up`
> copies to `.env` for customization; it is not read by Docker Compose
> directly. Copy it to `.env` only if you need custom values:
> `cp env.default .env`

## Requirements

- Docker Engine 20.10+ with Docker Compose V2
- Ports 11112-11115 available on the host (configurable via `.env`)

## Architecture

```
Host Machine
┌──────────────────────────────────────────────────────────┐
│ Docker Network: dicom-net                                │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐   │
│  │ pacs-server  │  │ pacs-server-2│  │ storescp-     │   │
│  │ (dcmqrscp)   │  │ (dcmqrscp)   │  │ receiver      │   │
│  │ AE:DCMTK_PACS│  │ AE:DCMTK_PAC2│  │ AE:STORE_SCP  │   │
│  │ :11112       │  │ :11112       │  │ :11112        │   │
│  └──────┬───────┘  └──────────────┘  └───────────────┘   │
│         │ C-ECHO/STORE/FIND/MOVE                         │
│  ┌──────┴───────┐                    ┌───────────────┐   │
│  │ test-client  │  C-FIND (MWL)      │ mwl-server    │   │
│  │ (SCU tools)  ├───────────────────>│ (wlmscpfs)    │   │
│  │ AE:TEST_SCU  │                    │ AE:DCMTK_WLM  │   │
│  └──────────────┘                    │ :11112        │   │
│                                      └───────────────┘   │
└──────────────────────────────────────────────────────────┘
  Host ports:  :11112  :11113  :11114  :11115
```

## Services

| Service | AE Title | Host Port | Role | Process |
|---------|----------|-----------|------|---------|
| pacs-server | `DCMTK_PACS` | 11112 | Primary PACS (C-ECHO, C-STORE, C-FIND, C-MOVE) | `dcmqrscp` |
| pacs-server-2 | `DCMTK_PAC2` | 11113 | Secondary PACS for multi-PACS testing | `dcmqrscp` |
| storescp-receiver | `STORE_SCP` | 11114 | C-MOVE destination / standalone receiver | `storescp` |
| mwl-server | `DCMTK_WLM` | 11115 | Modality Worklist SCP (`findscu -W`) | `wlmscpfs` |
| test-client | `TEST_SCU` | — | Interactive SCU tool container | `sleep infinity` |

All five services build from the same [`Dockerfile`](Dockerfile): `debian:bookworm-slim`
with DCMTK 3.6.7 from the Debian `dcmtk` package, both pinned there.
The `ROLE` environment variable selects which service to run.

## Capabilities

This is a **classic-DIMSE test PACS** built on DCMTK `dcmqrscp`. It is purpose-built
for deterministic, isolated testing of DICOM network (DIMSE) clients on uncompressed
data — not a drop-in replacement for a full clinical archive.

| Capability | Status | Notes |
|------------|:------:|-------|
| C-ECHO (Verification) | ✅ | Used as the DICOM-native healthcheck |
| C-STORE (Storage) | ✅ | Indexed into a real queryable `index.dat` archive |
| C-FIND (Query) | ✅ | Patient Root + Study Root; STUDY/SERIES levels tested |
| C-MOVE (Retrieve) | ✅ | Cross-node; destination AE must be in the HostTable |
| C-GET (Retrieve) | ✅ | `dcmqrscp` serves C-GET unless started with `--disable-get`, which the entrypoint does not pass; no test covers C-GET |
| Uncompressed transfer syntaxes | ✅ | Implicit VR LE, Explicit VR LE, Explicit VR BE |
| AE-title access control | ✅ | Opt-in restricted (whitelist) profile |
| Non-root container | ✅ | Network-facing PACS/receiver services run as the unprivileged `pacs` user (the test-client helper runs as root for host-mounted writes) |
| Compressed transfer syntaxes (JPEG / JPEG-LS / JPEG2000 / RLE) | ❌ | Not accepted: the entrypoint starts `dcmqrscp` with its default preference (`+x=`), which accepts only uncompressed syntaxes. The image has the JPEG, JPEG-LS, and RLE codec tools (`dcmcjpeg`, `dcmcjpls`, `dcmcrle`, and their decoders) but no JPEG 2000 codec |
| DICOMweb (WADO-RS / QIDO-RS / STOW-RS) | ❌ | Not a DCMTK feature |
| Modality Worklist (MWL) | ✅ | Served by `wlmscpfs` (`mwl-server`); query with `findscu -W` |
| MPPS | ❌ | DCMTK ships no MPPS SCP — use Orthanc / dcm4chee |
| Storage Commitment | ❌ | DCMTK ships no Storage-Commitment SCP — use dcm4chee |
| TLS / secure transport | ⚠️ | The Debian package is built with OpenSSL, and `storescp`, `storescu`, `echoscu`, and `findscu` accept `+tls`. `dcmqrscp` has TLS options only from DCMTK 3.6.9, so on this image (3.6.7) the TLS overlay (`docker-compose.tls.yml`) stops at startup |

For DICOMweb, MPPS / Storage-Commitment workflows, or compressed pixel data,
reach for [Orthanc](https://www.orthanc-server.com/) or
[dcm4chee-arc-light](https://github.com/dcm4che/dcm4chee-arc-light).

## CLI Wrapper (`pacs.sh`)

A unified CLI script wraps all common operations:

| Command | Action |
|---------|--------|
| `./pacs.sh up` | Auto-setup `.env`, build & start all services, wait for health |
| `./pacs.sh down` | Stop all services |
| `./pacs.sh status` | Show service health, ports, and AE titles |
| `./pacs.sh test [suite]` | Run tests (`all`, `echo`, `store`, `find`, `move`, `pixeldata`, `transfer-syntax`, `load-smoke`, `worklist`, `adhoc-peers`) |
| `./pacs.sh add-peer <name> <ae> <host> <port>` | Register an ad-hoc C-MOVE destination and restart the PACS |
| `./pacs.sh logs [service]` | Tail logs (all or specific service) |
| `./pacs.sh shell` | Interactive bash into test-client container |
| `./pacs.sh reset` | Wipe volumes and restart fresh |
| `./pacs.sh clean` | Remove all containers, images, and volumes |
| `./pacs.sh clean-data [--dry-run]` | Remove host-side generated DICOM data (preserves `data/dicom-templates` fixtures) |
| `./pacs.sh echo [host] [port] [called-ae] [calling-ae]` | Quick C-ECHO connectivity check |
| `./pacs.sh version` | Show the dcmtk-docker version |
| `./pacs.sh help` | Show usage with examples |

> The `restricted-mode` suite is run via a compose overlay, not `pacs.sh test`; see [Restricted AE whitelist profile](docs/10_security.md#restricted-ae-whitelist-profile-opt-in).

All `docker compose` commands still work directly if you prefer.

## Configuration

Copy `env.default` to `.env` and edit it to change host ports, AE titles,
resource limits, or ad-hoc C-MOVE peers.
[docs/09_configuration.md](docs/09_configuration.md) lists every variable with
its default and describes the `dcmqrscp` configuration templates.

## Security

The default configuration is for isolated test networks only and is **not safe
for production use**:

- Both PACS servers accept associations from any Calling AE Title (`ANY` Peers).
- Published ports bind to all host interfaces (`0.0.0.0`) unless
  `PACS_BIND_ADDR` names one, and Docker's published ports bypass host
  firewalls such as `ufw`.
- The opt-in restricted profile (`docker-compose.restricted.yml`) limits Calling
  AE Titles for the two PACS servers only; `storescp-receiver` and `mwl-server`
  accept any caller in every mode.

[docs/10_security.md](docs/10_security.md) covers the peer whitelist example,
hardening, the bind address, and the restricted profile.

## Documentation

| Page | Contents |
|------|----------|
| [DICOM operations](docs/07_dicom_operations.md) | Start and stop; C-ECHO, C-STORE, C-FIND, and C-MOVE examples; external applications |
| [Test suite and test data](docs/08_test_suite.md) | Suites, transfer syntaxes, load smoke, fixtures, synthetic PixelData |
| [Configuration](docs/09_configuration.md) | Environment variables and defaults; `dcmqrscp` templates |
| [Security notes](docs/10_security.md) | `ANY` peers, peer whitelist, hardening, bind address, restricted profile |
| [Troubleshooting](docs/11_troubleshooting.md) | Rejected associations, C-MOVE destinations, transfer syntaxes, missing data |
| [Project structure and development](docs/12_development.md) | Repository layout, rebuilds, the `custom` role, inspecting DICOM files |
| [dcmqridx behavior](docs/06_dcmqridx_behavior.md) | When the PACS indexes its test data |
| [README policy](docs/contributing/README_POLICY.md) | Rules that `scripts/readme_lint.py` enforces for this file |

Earlier design documents: [DCMTK and DICOM research](docs/01_research_dcmtk_dicom.md),
[Docker approaches](docs/02_research_docker_approaches.md),
[architecture design](docs/03_architecture_design.md),
[work plan](docs/04_work_plan.md), and the
[usage guide](docs/05_usage_guide.md), whose status example and variable list
predate `mwl-server`. Where they differ, this README and the pages above apply.

## License

Released under the MIT License. See [LICENSE](LICENSE) for the full text.
