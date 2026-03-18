# System Architecture Design

> Architecture document for the Docker-based DCMTK PACS test environment.
> Based on research from `01_research_dcmtk_dicom.md` and `02_research_docker_approaches.md`.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Container Design](#3-container-design)
4. [Service Definitions](#4-service-definitions)
5. [Network Design](#5-network-design)
6. [Storage Design](#6-storage-design)
7. [Configuration Management](#7-configuration-management)
8. [Test Data Strategy](#8-test-data-strategy)
9. [Project Directory Structure](#9-project-directory-structure)

---

## 1. System Overview

### Purpose

A universal PACS integration test environment built on Docker and DCMTK.
It provides a fully containerized, reproducible DICOM network that can be started
with a single `docker compose up` command.

### Target Users

- Developers testing DICOM connectivity and PACS integration
- QA engineers validating DICOM workflows (C-ECHO, C-STORE, C-FIND, C-MOVE)
- Teams needing a lightweight PACS for CI/CD pipeline testing
- Researchers evaluating DICOM protocol behavior

### Design Goals

| Goal | Description |
|------|-------------|
| **Simplicity** | Single `docker compose up` starts the full environment |
| **Reproducibility** | Synthetic test data generated at startup — no external dependencies |
| **Flexibility** | Single Docker image, multiple roles via entrypoint arguments |
| **Testability** | Pre-built test scripts for all DICOM operations |
| **Portability** | Works on Linux, macOS (ARM/x86), Windows (WSL2) |

---

## 2. Architecture Diagram

### Full System Topology

```
                        Host Machine
            ┌──────────────────────────────────────────────┐
            │                                              │
            │   Docker Network: dicom-net (bridge)         │
            │   ┌──────────────────────────────────────┐   │
            │   │                                      │   │
            │   │  ┌─────────────────┐                 │   │
            │   │  │  pacs-server    │                 │   │
            │   │  │  (dcmqrscp)     │                 │   │
  :11112 ───┼───┼──│  AE: DCMTK_PACS│                 │   │
            │   │  │  Port: 11112    │                 │   │
            │   │  │  Vol: pacs-data │                 │   │
            │   │  └──────┬──────────┘                 │   │
            │   │         │ C-ECHO/STORE/FIND/MOVE     │   │
            │   │         │                            │   │
            │   │  ┌──────┴──────────┐                 │   │
            │   │  │  pacs-server-2  │                 │   │
            │   │  │  (dcmqrscp)     │                 │   │
  :11113 ───┼───┼──│  AE: DCMTK_PAC2│                 │   │
            │   │  │  Port: 11112    │                 │   │
            │   │  │  Vol: pacs2-data│                 │   │
            │   │  └─────────────────┘                 │   │
            │   │                                      │   │
            │   │  ┌─────────────────┐                 │   │
            │   │  │  storescp-      │                 │   │
            │   │  │  receiver       │                 │   │
  :11114 ───┼───┼──│  (storescp)     │                 │   │
            │   │  │  AE: STORE_SCP  │                 │   │
            │   │  │  Port: 11112    │                 │   │
            │   │  │  Vol: received  │                 │   │
            │   │  └─────────────────┘                 │   │
            │   │                                      │   │
            │   │  ┌─────────────────┐                 │   │
            │   │  │  test-client    │                 │   │
            │   │  │  (sleep inf)    │                 │   │
            │   │  │  AE: TEST_SCU   │                 │   │
            │   │  │  Tools:         │                 │   │
            │   │  │   echoscu       │                 │   │
            │   │  │   storescu      │                 │   │
            │   │  │   findscu       │                 │   │
            │   │  │   movescu       │                 │   │
            │   │  └─────────────────┘                 │   │
            │   │                                      │   │
            │   └──────────────────────────────────────┘   │
            │                                              │
            └──────────────────────────────────────────────┘

            External PACS ──── :11112 ──── pacs-server
            (optional)         (host port)
```

### Data Flow Diagram

```
  ┌────────────┐     C-ECHO      ┌──────────────┐
  │            │ ───────────────> │              │
  │            │     C-STORE     │              │
  │ test-      │ ───────────────> │ pacs-server  │
  │ client     │     C-FIND      │ (dcmqrscp)   │
  │            │ ───────────────> │              │
  │            │     C-MOVE      │              │
  │            │ ───────────────> │              │
  └────────────┘                  └──────┬───────┘
                                         │
                          C-MOVE sends   │  C-STORE (reverse)
                          images to      │
                          destination    │
                                         v
                                  ┌──────────────┐
                                  │ storescp-    │
                                  │ receiver     │
                                  │ (storescp)   │
                                  └──────────────┘
```

### C-MOVE Detailed Flow

```
  test-client                 pacs-server              storescp-receiver
      │                           │                          │
      │  C-MOVE Request           │                          │
      │  -aem STORE_SCP           │                          │
      │ ────────────────────────> │                          │
      │                           │  C-STORE (new assoc.)    │
      │                           │ ───────────────────────> │
      │                           │                          │ stores images
      │                           │  C-STORE Response        │
      │                           │ <─────────────────────── │
      │  C-MOVE Response          │                          │
      │ <──────────────────────── │                          │
      │  (N images transferred)   │                          │
```

---

## 3. Container Design

### Single Image, Multiple Roles

A single Docker image contains all DCMTK tools and switches behavior via the
entrypoint script based on the `ROLE` environment variable.

```
┌──────────────────────────────────────────────┐
│  Docker Image: dcmtk-pacs                    │
│                                              │
│  Base: debian:bookworm-slim                  │
│  DCMTK: 3.6.7 (via apt)                     │
│                                              │
│  Installed Tools:                            │
│    Network: echoscu, storescu, storescp,     │
│             findscu, movescu, getscu,        │
│             dcmqrscp, dcmrecv, dcmsend       │
│    File:    dcmdump, dump2dcm, dcmodify,     │
│             dcmconv, img2dcm                 │
│    Utility: dcmqridx                         │
│                                              │
│  Custom Scripts:                             │
│    /usr/local/bin/entrypoint.sh              │
│    /usr/local/bin/generate-test-data.sh      │
│    /usr/local/bin/wait-for-pacs.sh           │
│                                              │
│  Entrypoint: /usr/local/bin/entrypoint.sh    │
│                                              │
│  Roles (via ROLE env):                       │
│    pacs-server  → dcmqrscp with config       │
│    storescp     → storescp receiver          │
│    test-client  → sleep infinity             │
│    custom       → pass-through to CMD        │
└──────────────────────────────────────────────┘
```

### Dockerfile Overview

```dockerfile
# Build stage (optional: for source build variant)
# Runtime stage
FROM debian:bookworm-slim

# Install DCMTK 3.6.7 and utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    dcmtk \
    && rm -rf /var/lib/apt/lists/*

# Copy configuration templates and scripts
COPY config/ /etc/dcmtk/
COPY scripts/ /usr/local/bin/

# Default DICOM port
EXPOSE 11112

# Entrypoint handles role selection
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### Entrypoint Role Selection

| Role | ROLE Value | Process Started | Description |
|------|-----------|----------------|-------------|
| PACS Server | `pacs-server` | `dcmqrscp -v -c /etc/dcmtk/dcmqrscp.cfg $DICOM_PORT` | Full PACS with Q/R |
| Store SCP | `storescp` | `storescp -v -od $STORAGE_DIR -aet $AE_TITLE $DICOM_PORT` | C-STORE receiver only |
| Test Client | `test-client` | `sleep infinity` | Interactive tool access |
| Custom | `custom` | Executes CMD arguments | User-defined command |

---

## 4. Service Definitions

### Docker Compose Services

#### pacs-server (Primary PACS)

| Property | Value |
|----------|-------|
| Process | `dcmqrscp` |
| AE Title | `DCMTK_PACS` |
| Internal Port | 11112 |
| Host Port | 11112 |
| Services | C-ECHO, C-STORE, C-FIND, C-MOVE |
| Storage | `pacs-data` named volume |
| Health Check | `echoscu localhost 11112` |

#### pacs-server-2 (Secondary PACS)

| Property | Value |
|----------|-------|
| Process | `dcmqrscp` |
| AE Title | `DCMTK_PAC2` |
| Internal Port | 11112 |
| Host Port | 11113 |
| Services | C-ECHO, C-STORE, C-FIND, C-MOVE |
| Storage | `pacs2-data` named volume |
| Health Check | `echoscu localhost 11112` |

Note: AE Title is `DCMTK_PAC2` (not `DCMTK_PACS2`) because DICOM AE Titles
have a 16-character maximum limit.

#### storescp-receiver (C-MOVE Destination)

| Property | Value |
|----------|-------|
| Process | `storescp` |
| AE Title | `STORE_SCP` |
| Internal Port | 11112 |
| Host Port | 11114 |
| Services | C-ECHO (implicit), C-STORE |
| Storage | `received-data` named volume |
| Health Check | TCP check on port 11112 |

#### test-client (SCU Tools)

| Property | Value |
|----------|-------|
| Process | `sleep infinity` |
| AE Title | `TEST_SCU` |
| Available Tools | echoscu, storescu, findscu, movescu, getscu |
| Test Data | Bind mount from `./data/` |
| Depends On | pacs-server (healthy) |

### Service Dependency Graph

```
  test-client
      │
      │ depends_on (service_healthy)
      v
  pacs-server ──────── pacs-server-2
      │                     │
      │ (independent)       │ (independent)
      v                     v
  storescp-receiver    (standalone)
```

### Docker Compose Summary

```yaml
services:
  pacs-server:       # dcmqrscp — primary PACS
  pacs-server-2:     # dcmqrscp — secondary PACS for multi-PACS testing
  storescp-receiver: # storescp — C-MOVE destination
  test-client:       # SCU tools container — interactive use

networks:
  dicom-net:         # Bridge network for all services

volumes:
  pacs-data:         # pacs-server storage
  pacs2-data:        # pacs-server-2 storage
  received-data:     # storescp-receiver storage
```

---

## 5. Network Design

### Docker Bridge Network

All containers connect to a single Docker bridge network named `dicom-net`.
Docker's embedded DNS provides service discovery — containers reference each other
by service name (e.g., `pacs-server`, `storescp-receiver`).

```
dicom-net (bridge)
├── pacs-server        → pacs-server:11112
├── pacs-server-2      → pacs-server-2:11112
├── storescp-receiver  → storescp-receiver:11112
└── test-client        → (no listening port)
```

### Port Mapping Strategy

| Service | Container Port | Host Port | Purpose |
|---------|---------------|-----------|---------|
| pacs-server | 11112 | 11112 | External PACS access |
| pacs-server-2 | 11112 | 11113 | External second PACS access |
| storescp-receiver | 11112 | 11114 | External store receiver access |
| test-client | — | — | No exposed ports |

**Internal communication** uses container port 11112 for all services.
**Host port mapping** uses different ports (11112, 11113, 11114) to avoid conflicts.

### External PACS Connectivity

External DICOM applications connect to the PACS through host-mapped ports:

```
External PACS/Viewer
    │
    │ C-ECHO/STORE/FIND/MOVE
    │ Host: <docker-host-ip>
    │ Port: 11112
    │ Called AE: DCMTK_PACS
    v
  pacs-server (inside Docker)
```

For C-MOVE from pacs-server to an external destination, the external application's
AE Title, hostname (from the container's perspective), and port must be added to the
dcmqrscp HostTable configuration.

### DICOM AE Title Registry

| AE Title | Service | Port (internal) | Role |
|----------|---------|-----------------|------|
| `DCMTK_PACS` | pacs-server | 11112 | Primary PACS (SCP) |
| `DCMTK_PAC2` | pacs-server-2 | 11112 | Secondary PACS (SCP) |
| `STORE_SCP` | storescp-receiver | 11112 | C-MOVE destination (SCP) |
| `TEST_SCU` | test-client | — | Test client (SCU) |

---

## 6. Storage Design

### Volume Architecture

```
Named Volumes (Docker-managed, persistent across restarts)
├── pacs-data        → /dicom/db        (pacs-server)
├── pacs2-data       → /dicom/db        (pacs-server-2)
└── received-data    → /dicom/received  (storescp-receiver)

Bind Mounts (host filesystem, editable from host)
├── ./config/        → /etc/dcmtk/      (all services, read-only)
├── ./data/          → /dicom/testdata   (test-client)
└── ./tests/         → /tests/           (test-client)
```

### Directory Structure Inside Containers

#### PACS Server Containers

```
/dicom/
├── db/
│   └── DCMTK_PACS/          # dcmqrscp storage area
│       ├── index.dat         # Auto-created database index
│       └── *.dcm             # Stored DICOM files
└── testdata/                 # Generated synthetic data (init only)
```

#### storescp-receiver Container

```
/dicom/
└── received/                 # Received DICOM files from C-MOVE
    └── *.dcm
```

#### test-client Container

```
/dicom/
└── testdata/                 # Bind-mounted from ./data/
    ├── ct/                   # CT test images
    ├── mr/                   # MR test images
    └── cr/                   # CR test images

/tests/                       # Bind-mounted from ./tests/
├── test-echo.sh
├── test-store.sh
├── test-find.sh
├── test-move.sh
└── test-all.sh
```

### Storage Considerations

1. **dcmqrscp creates `index.dat`** automatically in each storage directory on first run.
   The storage directory must exist before dcmqrscp starts.
2. **Named volumes** persist PACS data across container restarts.
   Use `docker compose down -v` to fully reset the environment.
3. **Bind mounts** for test data allow editing from the host without rebuilding.

---

## 7. Configuration Management

### Environment Variables

All tunable parameters are exposed as environment variables with sensible defaults.

#### Common Variables (All Services)

| Variable | Default | Description |
|----------|---------|-------------|
| `ROLE` | `pacs-server` | Container role: `pacs-server`, `storescp`, `test-client`, `custom` |
| `AE_TITLE` | `DCMTK_PACS` | Application Entity Title (max 16 chars) |
| `DICOM_PORT` | `11112` | DICOM listening port |
| `STORAGE_DIR` | `/dicom/db` | Storage directory for received files |
| `LOG_LEVEL` | `info` | Log verbosity: `debug`, `info`, `warn`, `error` |

#### PACS Server Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_PDU_SIZE` | `16384` | Maximum PDU size in bytes |
| `MAX_ASSOCIATIONS` | `16` | Maximum concurrent associations |
| `MAX_STUDIES` | `200` | Maximum studies per storage area |
| `MAX_BYTES_PER_STUDY` | `1024mb` | Maximum bytes per study |
| `PEERS` | `ANY` | Allowed peers (`ANY` or comma-separated) |

#### Test Data Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GENERATE_TEST_DATA` | `true` | Generate synthetic DICOM data on startup |
| `TEST_DATA_DIR` | `/dicom/testdata` | Output directory for generated data |
| `OID_ROOT` | `1.2.826.0.1.3680043.8.1055` | Private OID root for test UIDs |

### .env File

The `.env` file provides defaults for all Docker Compose variables:

```env
# PACS Server 1
PACS1_AE_TITLE=DCMTK_PACS
PACS1_PORT=11112

# PACS Server 2
PACS2_AE_TITLE=DCMTK_PAC2
PACS2_PORT=11113

# Store SCP Receiver
STORESCP_AE_TITLE=STORE_SCP
STORESCP_PORT=11114

# Test Client
TEST_SCU_AE_TITLE=TEST_SCU

# Shared Settings
MAX_PDU_SIZE=16384
MAX_ASSOCIATIONS=16
LOG_LEVEL=info
GENERATE_TEST_DATA=true
```

### dcmqrscp Configuration Template

The `dcmqrscp.cfg.template` file uses shell variable placeholders processed by
`envsubst` or `sed` at container startup:

```
# dcmqrscp.cfg — Generated from template
NetworkTCPPort  = ${DICOM_PORT}
MaxPDUSize      = ${MAX_PDU_SIZE}
MaxAssociations = ${MAX_ASSOCIATIONS}

HostTable BEGIN
  test_client   = (${TEST_SCU_AE_TITLE},  test-client,       11112)
  store_scp     = (${STORESCP_AE_TITLE},   storescp-receiver, 11112)
  pacs2         = (${PACS2_AE_TITLE},      pacs-server-2,     11112)
  all_peers     = test_client, store_scp, pacs2
HostTable END

VendorTable BEGIN
  "Test Peers" = all_peers
VendorTable END

AETable BEGIN
  ${AE_TITLE}  ${STORAGE_DIR}/${AE_TITLE}  RW  (${MAX_STUDIES}, ${MAX_BYTES_PER_STUDY})  ANY
AETable END
```

The entrypoint script processes the template before starting dcmqrscp:

```bash
envsubst < /etc/dcmtk/dcmqrscp.cfg.template > /tmp/dcmqrscp.cfg
mkdir -p "${STORAGE_DIR}/${AE_TITLE}"
exec dcmqrscp -v -c /tmp/dcmqrscp.cfg "$DICOM_PORT"
```

---

## 8. Test Data Strategy

### Synthetic DICOM Generation

Test data is generated at container initialization using `dump2dcm`.
No external datasets are downloaded — everything is self-contained.

### Test Dataset Specification

| Patient | PatientID | Modality | Studies | Series/Study | Instances/Series |
|---------|-----------|----------|---------|--------------|------------------|
| DOE^JOHN | PAT001 | CT | 1 | 1 | 5 |
| SMITH^JANE | PAT002 | MR | 1 | 2 | 3 each |
| WANG^LEI | PAT003 | CR | 1 | 1 | 2 |

**Total**: 3 patients, 3 studies, 4 series, 13 instances.

### UID Strategy

All test UIDs use a private OID root to prevent collision with real clinical data:

```
Root:   1.2.826.0.1.3680043.8.1055
Format: {root}.{patient}.{study}.{series}.{instance}

Examples:
  Study:    1.2.826.0.1.3680043.8.1055.1.1          (patient 1, study 1)
  Series:   1.2.826.0.1.3680043.8.1055.1.1.1        (patient 1, study 1, series 1)
  Instance: 1.2.826.0.1.3680043.8.1055.1.1.1.1      (... instance 1)
```

### Generation Flow

```
Container Start
    │
    ├── ROLE=pacs-server & GENERATE_TEST_DATA=true
    │       │
    │       ├── Run generate-test-data.sh
    │       │       │
    │       │       ├── Create dump files from templates
    │       │       ├── dump2dcm → .dcm files in /dicom/testdata/
    │       │       └── storescu → send to local dcmqrscp
    │       │
    │       └── Start dcmqrscp
    │
    └── ROLE=test-client
            │
            └── Test data available via bind mount ./data/
```

### DICOM Dump Templates

Templates are stored in `data/dicom-templates/` and parameterized for batch generation.
Each template contains the minimum required DICOM attributes:

- File Meta Information (Group 0002)
- Patient Module (Group 0010)
- General Study Module (Group 0008, 0020)
- General Series Module (Group 0020)
- SOP Common Module (Group 0008)
- Modality-specific attributes (e.g., Rows/Columns for image SOP classes)

---

## 9. Project Directory Structure

```
dcmtk_docker/
├── Dockerfile                        # Single image: debian:bookworm-slim + DCMTK 3.6.7
├── docker-compose.yml                # 4 services: pacs-server, pacs-server-2,
│                                     #   storescp-receiver, test-client
├── .env                              # Default environment variables
├── .dockerignore                     # Exclude docs, .git, etc. from build context
├── README.md                         # Usage guide, quick start, examples
│
├── config/                           # Configuration files (bind-mounted read-only)
│   ├── dcmqrscp.cfg.template        # dcmqrscp config with variable placeholders
│   └── dcmqrscp-pacs2.cfg.template  # Config template for secondary PACS
│
├── scripts/                          # Container scripts (copied into image)
│   ├── entrypoint.sh                # Role-based startup dispatcher
│   ├── generate-test-data.sh        # Synthetic DICOM file generation
│   └── wait-for-pacs.sh             # Readiness polling script
│
├── data/                             # Test data (bind-mounted into test-client)
│   └── dicom-templates/             # dump2dcm template files
│       ├── ct-template.dump         # CT Image template
│       ├── mr-template.dump         # MR Image template
│       └── cr-template.dump         # CR Image template
│
├── tests/                            # Test scripts (bind-mounted into test-client)
│   ├── test-echo.sh                 # C-ECHO connectivity test
│   ├── test-store.sh                # C-STORE archival test
│   ├── test-find.sh                 # C-FIND query test
│   ├── test-move.sh                 # C-MOVE retrieval test
│   └── test-all.sh                  # Run all tests in sequence
│
└── docs/                             # Documentation (not in Docker image)
    ├── 01_research_dcmtk_dicom.md   # DCMTK & DICOM protocol research
    ├── 02_research_docker_approaches.md  # Docker approaches research
    ├── 03_architecture_design.md    # This document
    └── 04_work_plan.md              # Implementation work plan
```

### File Purposes

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the unified DCMTK image with all tools and scripts |
| `docker-compose.yml` | Defines 4 services, network, and volumes |
| `.env` | Default values for all configurable parameters |
| `.dockerignore` | Keeps build context small (excludes docs, .git, data) |
| `config/dcmqrscp.cfg.template` | dcmqrscp configuration with `envsubst` variables |
| `scripts/entrypoint.sh` | Reads `ROLE` env var, processes config templates, starts service |
| `scripts/generate-test-data.sh` | Creates synthetic DICOM files from templates using `dump2dcm` |
| `scripts/wait-for-pacs.sh` | Polls a PACS with `echoscu` until it responds (used in depends_on) |
| `data/dicom-templates/*.dump` | dump2dcm input templates for CT, MR, CR modalities |
| `tests/test-*.sh` | Individual DICOM operation test scripts |
| `tests/test-all.sh` | Orchestrates all tests with pass/fail reporting |

---

*Document generated: 2026-03-19 | For: dcmtk_docker project — Docker-based PACS test environment*
