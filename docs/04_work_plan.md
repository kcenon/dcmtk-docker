# Implementation Work Plan

> Step-by-step implementation plan for the Docker-based DCMTK PACS test environment.
> References `03_architecture_design.md` for all architectural decisions.

---

## Table of Contents

1. [Phase Overview](#1-phase-overview)
2. [Phase 3A: Docker Infrastructure](#2-phase-3a-docker-infrastructure)
3. [Phase 3B: Configuration and Scripts](#3-phase-3b-configuration-and-scripts)
4. [Phase 3C: Test Scripts](#4-phase-3c-test-scripts)
5. [Phase 4: Documentation](#5-phase-4-documentation)
6. [Test Criteria Summary](#6-test-criteria-summary)
7. [Risk Assessment](#7-risk-assessment)

---

## 1. Phase Overview

```
Phase 3A: Docker Infrastructure
    │   Dockerfile, docker-compose.yml, .env, .dockerignore
    │
    v
Phase 3B: Configuration & Scripts
    │   dcmqrscp.cfg templates, entrypoint.sh, generate-test-data.sh,
    │   wait-for-pacs.sh, DICOM dump templates
    │
    v
Phase 3C: Test Scripts
    │   test-echo.sh, test-store.sh, test-find.sh,
    │   test-move.sh, test-all.sh
    │
    v
Phase 4: Documentation
        README.md
```

| Phase | Description | Files | Dependencies |
|-------|-------------|-------|--------------|
| **3A** | Docker Infrastructure | 4 files | None |
| **3B** | Configuration & Scripts | 8 files | Phase 3A |
| **3C** | Test Scripts | 5 files | Phase 3A + 3B |
| **4** | Documentation | 1 file | Phase 3A + 3B + 3C |

---

## 2. Phase 3A: Docker Infrastructure

### Goal

Create the core Docker build and orchestration files. After this phase, `docker compose build`
succeeds and containers start (though services are not yet functional without Phase 3B scripts).

### Files to Create

#### 2.1 Dockerfile

**Path**: `dcmtk_docker/Dockerfile`

**What it does**:
- Based on `debian:bookworm-slim`
- Installs DCMTK 3.6.7 via `apt-get install dcmtk`
- Copies configuration templates to `/etc/dcmtk/`
- Copies scripts to `/usr/local/bin/` and makes them executable
- Creates required directories (`/dicom/db`, `/dicom/testdata`, `/dicom/received`)
- Exposes port 11112
- Sets entrypoint to `/usr/local/bin/entrypoint.sh`

**Implementation notes**:
- Use `--no-install-recommends` to minimize image size
- Clean apt cache in the same RUN layer
- Install `gettext-base` for `envsubst` command (config template processing)

**Priority**: 1 (must be first)

**Dependencies**: None

#### 2.2 docker-compose.yml

**Path**: `dcmtk_docker/docker-compose.yml`

**What it does**:
Defines 4 services, 1 network, and 3 named volumes as specified in the architecture doc.

**Services**:

| Service | Build | ROLE | AE_TITLE | Ports | Volumes | Health Check | Depends On |
|---------|-------|------|----------|-------|---------|-------------|------------|
| pacs-server | `.` | `pacs-server` | `DCMTK_PACS` | `11112:11112` | `pacs-data:/dicom/db`, `./config:/etc/dcmtk:ro` | echoscu | — |
| pacs-server-2 | `.` | `pacs-server` | `DCMTK_PAC2` | `11113:11112` | `pacs2-data:/dicom/db`, `./config:/etc/dcmtk:ro` | echoscu | — |
| storescp-receiver | `.` | `storescp` | `STORE_SCP` | `11114:11112` | `received-data:/dicom/received` | TCP check | — |
| test-client | `.` | `test-client` | `TEST_SCU` | — | `./data:/dicom/testdata:ro`, `./tests:/tests:ro` | — | pacs-server (healthy) |

**Priority**: 2

**Dependencies**: Dockerfile (for build context reference)

#### 2.3 .env

**Path**: `dcmtk_docker/.env`

**What it does**:
Default values for all Docker Compose environment variables.

**Contents**:
- AE titles for all 4 services
- Port mappings
- dcmqrscp tuning parameters (MaxPDU, MaxAssociations)
- Test data generation flag
- Log level
- OID root for synthetic UIDs

**Priority**: 2 (same as docker-compose.yml)

**Dependencies**: None

#### 2.4 .dockerignore

**Path**: `dcmtk_docker/.dockerignore`

**What it does**:
Excludes non-build files from the Docker build context.

**Entries**: `docs/`, `.git/`, `.env`, `README.md`, `*.md`, `data/`, `tests/`

**Priority**: 3

**Dependencies**: None

### Phase 3A: Verification Criteria

| # | Criterion | Command | Expected Result |
|---|-----------|---------|-----------------|
| 1 | Image builds | `docker compose build` | Exits 0, image created |
| 2 | Image size | `docker images dcmtk_docker-pacs-server` | < 250 MB |
| 3 | DCMTK installed | `docker run --rm dcmtk_docker-pacs-server echoscu --version` | Prints version 3.6.7 |
| 4 | All tools present | `docker run --rm dcmtk_docker-pacs-server which dcmqrscp storescu findscu movescu dump2dcm` | All paths found |

---

## 3. Phase 3B: Configuration and Scripts

### Goal

Create all configuration templates and runtime scripts. After this phase,
`docker compose up` starts a fully functional PACS server with synthetic test data.

### Files to Create

#### 3.1 entrypoint.sh

**Path**: `dcmtk_docker/scripts/entrypoint.sh`

**What it does**:
1. Reads the `ROLE` environment variable
2. Sets default values for all environment variables if not provided
3. For `pacs-server` role:
   - Processes `dcmqrscp.cfg.template` via `envsubst` to generate runtime config
   - Creates storage directories (e.g., `/dicom/db/${AE_TITLE}`)
   - Optionally generates test data if `GENERATE_TEST_DATA=true`
   - Starts `dcmqrscp` with verbose logging
4. For `storescp` role:
   - Creates receive directory
   - Starts `storescp` with output directory
5. For `test-client` role:
   - Optionally generates test data
   - Runs `sleep infinity` to keep container alive
6. For `custom` role:
   - Executes the CMD arguments (`exec "$@"`)

**Priority**: 1 (critical — all services depend on it)

**Dependencies**: Dockerfile (copies this script)

#### 3.2 dcmqrscp.cfg.template (Primary PACS)

**Path**: `dcmtk_docker/config/dcmqrscp.cfg.template`

**What it does**:
Template for the primary PACS server configuration. Uses `${VARIABLE}` placeholders
that `envsubst` replaces at runtime.

**Sections**:
- Global: `NetworkTCPPort`, `MaxPDUSize`, `MaxAssociations`
- HostTable: Defines `test_client`, `store_scp`, `pacs2` peers
- VendorTable: Groups all peers
- AETable: Single storage area with configurable path, access mode, and limits

**Priority**: 1

**Dependencies**: entrypoint.sh (processes this template)

#### 3.3 dcmqrscp-pacs2.cfg.template (Secondary PACS)

**Path**: `dcmtk_docker/config/dcmqrscp-pacs2.cfg.template`

**What it does**:
Template for the secondary PACS server. Same structure as primary but:
- Different AE Title (`DCMTK_PAC2`)
- HostTable points to `pacs-server` (primary) and `storescp-receiver`
- Storage path uses `DCMTK_PAC2` subdirectory

**Priority**: 2

**Dependencies**: dcmqrscp.cfg.template (same structure)

#### 3.4 generate-test-data.sh

**Path**: `dcmtk_docker/scripts/generate-test-data.sh`

**What it does**:
1. Reads OID root and output directory from environment
2. Generates dump files for 3 test patients (CT, MR, CR) using heredocs
3. Runs `dump2dcm` to create DICOM files from dumps
4. Organizes output by modality: `ct/`, `mr/`, `cr/` subdirectories
5. Reports summary (file count, total size)

**Patient data**:

| Patient | ID | Modality | Instances |
|---------|----|----------|-----------|
| DOE^JOHN | PAT001 | CT | 5 slices |
| SMITH^JANE | PAT002 | MR | 6 (2 series x 3) |
| WANG^LEI | PAT003 | CR | 2 |

**Priority**: 2

**Dependencies**: DCMTK tools (dump2dcm) installed in image

#### 3.5 wait-for-pacs.sh

**Path**: `dcmtk_docker/scripts/wait-for-pacs.sh`

**What it does**:
1. Accepts PACS host, port, and optional AE title as arguments
2. Polls with `echoscu` up to 30 attempts (2-second intervals)
3. Exits 0 on success, 1 on timeout
4. Used by test scripts to wait for PACS readiness

**Priority**: 3

**Dependencies**: echoscu (installed in image)

#### 3.6 DICOM Dump Templates

**Paths**:
- `dcmtk_docker/data/dicom-templates/ct-template.dump`
- `dcmtk_docker/data/dicom-templates/mr-template.dump`
- `dcmtk_docker/data/dicom-templates/cr-template.dump`

**What they do**:
Parameterized dump2dcm input files for each modality. Used by `generate-test-data.sh`
as a reference (the actual generation uses heredocs with variable substitution,
but these templates serve as documentation and alternative generation method).

Each template contains:
- File Meta Information (transfer syntax, SOP class)
- Patient attributes (name, ID, sex, birth date)
- Study attributes (date, time, accession number, description)
- Series attributes (modality, series number)
- Instance attributes (instance number)
- Modality-specific attributes:
  - CT: Rows=256, Columns=256, BitsAllocated=16, BitsStored=12
  - MR: Rows=256, Columns=256, BitsAllocated=16, BitsStored=16
  - CR: Rows=512, Columns=512, BitsAllocated=16, BitsStored=12

**Priority**: 3

**Dependencies**: None

### Phase 3B: Verification Criteria

| # | Criterion | Command | Expected Result |
|---|-----------|---------|-----------------|
| 1 | Services start | `docker compose up -d` | All 4 containers running |
| 2 | PACS healthy | `docker compose ps` | pacs-server shows "healthy" |
| 3 | C-ECHO from client | `docker compose exec test-client echoscu pacs-server 11112` | Exit 0 |
| 4 | Test data generated | `docker compose exec pacs-server ls /dicom/testdata/` | Shows .dcm files |
| 5 | Config rendered | `docker compose exec pacs-server cat /tmp/dcmqrscp.cfg` | No `${...}` placeholders |
| 6 | Logs clean | `docker compose logs pacs-server` | No errors, shows "listening" |

---

## 4. Phase 3C: Test Scripts

### Goal

Create comprehensive test scripts that validate all DICOM operations. Each script
is self-contained and reports pass/fail status. After this phase, `test-all.sh`
exercises the full DICOM workflow.

### Files to Create

#### 4.1 test-echo.sh

**Path**: `dcmtk_docker/tests/test-echo.sh`

**What it does**:
1. Tests C-ECHO to pacs-server (DCMTK_PACS)
2. Tests C-ECHO to pacs-server-2 (DCMTK_PAC2)
3. Tests C-ECHO to storescp-receiver (STORE_SCP)
4. Tests C-ECHO with wrong AE Title (expects failure)
5. Tests C-ECHO with wrong port (expects failure)
6. Reports pass/fail for each test case

**Priority**: 1

**Dependencies**: All services running (Phase 3A + 3B)

#### 4.2 test-store.sh

**Path**: `dcmtk_docker/tests/test-store.sh`

**What it does**:
1. Generates test DICOM files if not present (using generate-test-data.sh)
2. Stores a single CT image to pacs-server via `storescu`
3. Stores multiple images (directory) to pacs-server
4. Stores images to pacs-server-2
5. Verifies stored images exist via C-FIND query
6. Reports pass/fail for each test case

**Priority**: 1

**Dependencies**: test-echo.sh (connectivity should work first)

#### 4.3 test-find.sh

**Path**: `dcmtk_docker/tests/test-find.sh`

**What it does**:
1. Pre-loads test data into PACS if not already present
2. Queries at STUDY level with wildcard PatientName
3. Queries at STUDY level with specific PatientID
4. Queries at SERIES level within a known study
5. Queries with date range filter
6. Queries with modality filter
7. Verifies result count matches expected values
8. Reports pass/fail for each test case

**Priority**: 2

**Dependencies**: test-store.sh (data must be in PACS)

#### 4.4 test-move.sh

**Path**: `dcmtk_docker/tests/test-move.sh`

**What it does**:
1. Pre-loads test data into PACS if not already present
2. Clears storescp-receiver storage
3. Issues C-MOVE for a specific study to STORE_SCP
4. Verifies files appear in storescp-receiver's received directory
5. Verifies file count matches expected instances
6. Issues C-MOVE for a patient (all studies)
7. Reports pass/fail for each test case

**C-MOVE prerequisite check**:
- Verifies STORE_SCP is listed in pacs-server's HostTable
- Verifies storescp-receiver is listening and reachable

**Priority**: 2

**Dependencies**: test-store.sh (data must be in PACS), storescp-receiver running

#### 4.5 test-all.sh

**Path**: `dcmtk_docker/tests/test-all.sh`

**What it does**:
1. Waits for all PACS services to be healthy (using wait-for-pacs.sh)
2. Runs test-echo.sh
3. Runs test-store.sh
4. Runs test-find.sh
5. Runs test-move.sh
6. Collects results from all test scripts
7. Prints summary table: total tests, passed, failed
8. Exits with non-zero if any test failed

**Output format**:
```
========================================
  DCMTK PACS Test Suite
========================================

[PASS] C-ECHO: pacs-server connectivity
[PASS] C-ECHO: pacs-server-2 connectivity
[PASS] C-ECHO: storescp-receiver connectivity
[PASS] C-STORE: single file to pacs-server
[PASS] C-STORE: directory to pacs-server
[PASS] C-FIND: wildcard patient query
[PASS] C-FIND: specific patient query
[PASS] C-MOVE: study retrieval to storescp-receiver
[FAIL] C-MOVE: patient retrieval (expected 13, got 0)

========================================
  Results: 8/9 passed, 1 failed
========================================
```

**Priority**: 3

**Dependencies**: All individual test scripts

### Phase 3C: Verification Criteria

| # | Criterion | Command | Expected Result |
|---|-----------|---------|-----------------|
| 1 | Echo tests pass | `docker compose exec test-client /tests/test-echo.sh` | All pass |
| 2 | Store tests pass | `docker compose exec test-client /tests/test-store.sh` | All pass |
| 3 | Find tests pass | `docker compose exec test-client /tests/test-find.sh` | All pass |
| 4 | Move tests pass | `docker compose exec test-client /tests/test-move.sh` | All pass |
| 5 | Full suite passes | `docker compose exec test-client /tests/test-all.sh` | Exit 0, summary OK |

---

## 5. Phase 4: Documentation

### Goal

Create a comprehensive README that enables users to get started quickly.

### Files to Create

#### 5.1 README.md

**Path**: `dcmtk_docker/README.md`

**Sections**:

1. **Overview** — What this project is, what it provides
2. **Quick Start** — 3-step getting started (`git clone`, `docker compose up`, `docker compose exec test-client /tests/test-all.sh`)
3. **Architecture** — Reference to architecture doc, brief ASCII diagram
4. **Services** — Table of all services with AE titles, ports, roles
5. **Usage Examples**:
   - Run a C-ECHO test
   - Store DICOM files from host
   - Query the PACS
   - Retrieve images via C-MOVE
   - Connect an external DICOM viewer
6. **Configuration** — Environment variables table, how to customize
7. **Test Data** — How synthetic data is generated, how to add custom data
8. **Test Scripts** — Available tests, how to run them
9. **Troubleshooting** — Common issues and solutions
10. **Development** — How to rebuild, clean, reset

**Priority**: 1 (only file in this phase)

**Dependencies**: All prior phases completed

### Phase 4: Verification Criteria

| # | Criterion | Check | Expected Result |
|---|-----------|-------|-----------------|
| 1 | Quick Start works | Follow README steps from scratch | Environment runs, tests pass |
| 2 | Examples work | Run each usage example | All produce expected output |
| 3 | No broken references | Check all file paths mentioned | All files exist |

---

## 6. Test Criteria Summary

### End-to-End Acceptance Test

The full system is "done" when the following sequence succeeds:

```bash
# 1. Clone and start
cd dcmtk_docker
docker compose up -d --build

# 2. Wait for health checks
docker compose exec test-client /usr/local/bin/wait-for-pacs.sh pacs-server 11112

# 3. Run all tests
docker compose exec test-client /tests/test-all.sh
# Expected: All tests pass, exit code 0

# 4. External access (from host)
echoscu localhost 11112
# Expected: Success (if DCMTK installed on host)

# 5. Clean shutdown
docker compose down -v
# Expected: All containers stopped, volumes removed
```

### Per-Phase Done Criteria

| Phase | Done When |
|-------|-----------|
| 3A | `docker compose build` succeeds, all DCMTK tools available in image |
| 3B | `docker compose up` starts all services, C-ECHO works between containers |
| 3C | `test-all.sh` passes all tests (C-ECHO, C-STORE, C-FIND, C-MOVE) |
| 4 | README Quick Start works from a clean checkout |

---

## 7. Risk Assessment

### Identified Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **DCMTK 3.6.7 missing features** | Low | Medium | 3.6.7 supports all needed features (C-ECHO, C-STORE, C-FIND, C-MOVE). 3.7.0 source build available as upgrade path. |
| **dcmqrscp config syntax errors** | Medium | High | Validate config at container start. Use `dcmqrscp -c config.cfg --check` if available, else test with C-ECHO immediately. |
| **C-MOVE HostTable misconfiguration** | High | High | Most common DICOM setup issue. HostTable must exactly match service names. Entrypoint generates config dynamically from environment variables. |
| **ARM vs x86 compatibility** | Low | Medium | `debian:bookworm-slim` is multi-arch. DCMTK apt package available for both `amd64` and `arm64`. |
| **dump2dcm output not accepted by dcmqrscp** | Medium | Medium | Validate generated files with `dcmdump` and test `storescu` to local server as part of init. |
| **Docker DNS resolution timing** | Low | Low | Use `depends_on: condition: service_healthy` and `wait-for-pacs.sh` retry script. |
| **Volume permissions** | Medium | Medium | Ensure storage directories are writable. `dcmqrscp` runs as root in container (acceptable for test env). |
| **Container port conflicts on host** | Low | Low | Ports 11112-11114 are non-standard. `.env` allows customization. |

### DCMTK Version Compatibility Notes

| Feature | DCMTK 3.6.7 (apt) | DCMTK 3.7.0 (source) |
|---------|-------------------|----------------------|
| dcmqrscp | Yes | Yes |
| C-ECHO/STORE/FIND/MOVE | Yes | Yes |
| dump2dcm | Yes | Yes |
| img2dcm | Yes | Yes |
| TLS support | Yes | Yes (improved) |
| DICOMweb | No | No (not a DCMTK feature) |
| JSON export | Limited | Improved |

DCMTK 3.6.7 from Debian Bookworm is sufficient for all planned functionality.

### Platform-Specific Concerns

| Platform | Concern | Mitigation |
|----------|---------|------------|
| **macOS (Apple Silicon)** | Docker runs in a VM; file I/O slower with bind mounts | Named volumes for PACS storage (fast); bind mounts only for config/tests |
| **macOS (Docker Desktop)** | Port forwarding through VM | Works transparently via Docker Desktop |
| **Linux** | No known issues | Native Docker performance |
| **Windows (WSL2)** | File path differences, line endings | Use LF line endings; test scripts use `#!/bin/bash` |

---

*Document generated: 2026-03-19 | For: dcmtk_docker project — Docker-based PACS test environment*
