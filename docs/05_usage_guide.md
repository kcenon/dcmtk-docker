# Usage Guide

> Detailed usage guide for the DCMTK PACS Docker test environment.
> For a quick overview, see the project [README.md](../README.md).

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Getting Started](#2-getting-started)
3. [Service Management](#3-service-management)
4. [DICOM Operations](#4-dicom-operations)
5. [Working with Test Data](#5-working-with-test-data)
6. [Configuration Reference](#6-configuration-reference)
7. [Advanced Scenarios](#7-advanced-scenarios)
8. [Troubleshooting Guide](#8-troubleshooting-guide)
9. [Common Test Scenarios](#9-common-test-scenarios)

---

## 1. Prerequisites

| Requirement | Minimum Version | Check Command |
|-------------|----------------|---------------|
| Docker Engine | 20.10+ | `docker --version` |
| Docker Compose | V2 (built-in) | `docker compose version` |
| Disk space | ~200 MB | — |
| Available ports | 11112-11114 | `lsof -i :11112` |

Optional (for host-side DICOM operations):
- DCMTK tools installed locally: `apt install dcmtk` / `brew install dcmtk`

---

## 2. Getting Started

### First-Time Setup

```bash
# Clone or navigate to the project
cd dcmtk_docker

# Start all services (auto-creates .env from env.default if needed)
./pacs.sh up
```

The `up` command automatically:
1. Copies `env.default` to `.env` if `.env` doesn't exist
2. Builds the Docker image and starts all 4 services
3. Waits for health checks to pass
4. Displays a status table showing service health, ports, and AE titles

> **Note:** Even without running `./pacs.sh up`, `docker compose` commands work
> directly — the `env_file` directive in `docker-compose.yml` reads `env.default`
> as a fallback when `.env` doesn't exist.

### Verify the Environment

```bash
# Check service status
./pacs.sh status

# Expected output:
# SERVICE              STATUS       AE TITLE       PORT
# pacs-server          healthy      DCMTK_PACS     11112
# pacs-server-2        healthy      DCMTK_PAC2     11113
# storescp-receiver    healthy      STORE_SCP      11114
# test-client          running      TEST_SCU       -

# Run the full test suite
./pacs.sh test
```

### What Happens on Startup

1. Docker builds a single image from `Dockerfile` (debian:bookworm-slim + DCMTK 3.6.7)
2. Four containers start, each with a different `ROLE`:
   - `pacs-server`: processes `dcmqrscp-primary.cfg.template` → starts `dcmqrscp`
   - `pacs-server-2`: processes `dcmqrscp-secondary.cfg.template` → starts `dcmqrscp`
   - `storescp-receiver`: starts `storescp` with output directory
   - `test-client`: generates test data → runs `sleep infinity`
3. Health checks run C-ECHO every 10 seconds to verify PACS readiness
4. `test-client` waits for `pacs-server` to be healthy before starting

---

## 3. Service Management

### CLI Wrapper (`pacs.sh`)

The `pacs.sh` script wraps all common operations into short subcommands:

| Command | Action |
|---------|--------|
| `./pacs.sh up` | Auto-setup `.env`, build & start, wait for health |
| `./pacs.sh down` | Stop all services |
| `./pacs.sh status` | Show service health, ports, and AE titles |
| `./pacs.sh test [suite]` | Run tests (`all`, `echo`, `store`, `find`, `move`) |
| `./pacs.sh logs [service]` | Tail logs (all or specific service) |
| `./pacs.sh shell` | Interactive bash into test-client container |
| `./pacs.sh reset` | Wipe volumes and restart fresh |
| `./pacs.sh clean` | Remove all containers, images, and volumes |
| `./pacs.sh echo [host] [port]` | Quick C-ECHO connectivity check |
| `./pacs.sh help` | Show usage with examples |

All `docker compose` commands still work directly if preferred.

### Starting Services

```bash
# Start all services (recommended)
./pacs.sh up

# Or use docker compose directly
docker compose up -d

# Start specific services
docker compose up -d pacs-server test-client

# Start with fresh build
docker compose up -d --build
```

### Stopping Services

```bash
# Stop all services (volumes preserved)
./pacs.sh down

# Stop and remove all data volumes
docker compose down -v

# Stop a specific service
docker compose stop pacs-server-2
```

### Viewing Logs

```bash
# All services (follow mode)
./pacs.sh logs

# Specific service
./pacs.sh logs pacs-server

# Last 50 lines
docker compose logs --tail 50 pacs-server
```

### Service Health

```bash
# Status table with health, ports, and AE titles
./pacs.sh status

# Manual health check
./pacs.sh echo localhost 11112
```

### Restarting Services

```bash
# Fresh restart (wipe volumes and rebuild)
./pacs.sh reset

# Restart a single service
docker compose restart pacs-server

# Force recreate (applies config changes)
docker compose up -d --force-recreate
```

---

## 4. DICOM Operations

All commands below are run from the test-client container unless stated otherwise.
Prefix commands with `docker compose exec test-client` when running from the host.

### 4.1 C-ECHO (Verification / Connectivity Test)

Tests basic DICOM connectivity — the "DICOM ping."

```bash
# Test primary PACS
echoscu -v -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112

# Test secondary PACS
echoscu -v -aet TEST_SCU -aec DCMTK_PAC2 pacs-server-2 11112

# Test store receiver
echoscu -v -aet TEST_SCU -aec STORE_SCP storescp-receiver 11112

# With timeout (useful for scripts)
echoscu -to 5 -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112
echo $?  # 0 = success
```

### 4.2 C-STORE (Send / Archive Images)

Sends DICOM files to a PACS for storage.

```bash
# Store a single file
storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    pacs-server 11112 /dicom/testdata/ct/ct_pat001_1.dcm

# Store an entire directory recursively
storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/

# Store to secondary PACS
storescu -v -aet TEST_SCU -aec DCMTK_PAC2 \
    +sd +r pacs-server-2 11112 /dicom/testdata/ct/
```

### 4.3 C-FIND (Query)

Searches the PACS database. Specify which attributes to return using `-k` flags.
Empty `-k` values (no `=`) request the attribute in the response.

#### Study-Level Queries

```bash
# Find all studies
findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="*" \
    -k PatientID \
    -k StudyDate \
    -k StudyDescription \
    -k ModalitiesInStudy \
    -k StudyInstanceUID \
    -k NumberOfStudyRelatedSeries \
    -k NumberOfStudyRelatedInstances

# Find by patient name (wildcard)
findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="DOE*" \
    -k StudyInstanceUID

# Find by patient ID
findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientID="PAT001" \
    -k StudyDate \
    -k StudyInstanceUID

# Find by date range
findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k StudyDate="20240101-20240331" \
    -k PatientName \
    -k StudyInstanceUID

# Find by modality
findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k ModalitiesInStudy="MR" \
    -k PatientName \
    -k StudyInstanceUID
```

#### Series-Level Queries

```bash
# Find series within a known study
findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=SERIES \
    -k StudyInstanceUID="1.2.826.0.1.3680043.8.499.2.1" \
    -k SeriesInstanceUID \
    -k Modality \
    -k SeriesNumber \
    -k SeriesDescription
```

### 4.4 C-MOVE (Retrieve)

Requests the PACS to send images to a registered destination.
The destination must be listed in the PACS HostTable.

```bash
# Retrieve a study to storescp-receiver
movescu -v -S -aet TEST_SCU -aec DCMTK_PACS -aem STORE_SCP \
    pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k StudyInstanceUID="1.2.826.0.1.3680043.8.499.1.1"

# Retrieve to secondary PACS
movescu -v -S -aet TEST_SCU -aec DCMTK_PACS -aem DCMTK_PAC2 \
    pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k StudyInstanceUID="1.2.826.0.1.3680043.8.499.1.1"
```

**C-MOVE parameters explained:**
- `-aet TEST_SCU`: Who is requesting (calling AE)
- `-aec DCMTK_PACS`: Who to ask (called AE — the PACS)
- `-aem STORE_SCP`: Where to send the images (move destination AE)

### 4.5 File Inspection

```bash
# Dump all DICOM attributes
dcmdump /dicom/testdata/ct/ct_pat001_1.dcm

# Dump specific attributes
dcmdump +P PatientName +P StudyInstanceUID +P Modality \
    /dicom/testdata/ct/ct_pat001_1.dcm

# Show with value lengths
dcmdump +L /dicom/testdata/ct/ct_pat001_1.dcm
```

---

## 5. Working with Test Data

### Automatically Generated Data

On first startup with `GENERATE_TEST_DATA=true`, the system creates synthetic DICOM files:

| Patient | PatientID | Modality | Study UID | Series | Instances |
|---------|-----------|----------|-----------|--------|-----------|
| DOE^JOHN | PAT001 | CT | `{OID_ROOT}.1.1` | 1 (Axial 5mm) | 5 |
| SMITH^JANE | PAT002 | MR | `{OID_ROOT}.2.1` | 2 (T1, T2 Axial) | 3 + 3 |
| WANG^LEI | PAT003 | CR | `{OID_ROOT}.3.1` | 1 (Chest) | 2 |

Default `OID_ROOT`: `1.2.826.0.1.3680043.8.499`

### Adding Custom DICOM Files

Place DICOM files in the `data/` directory. They will be available in the test-client
at `/dicom/testdata/`.

```bash
# Copy files to data directory on host
cp /path/to/your/files/*.dcm data/

# Files are immediately available in test-client
docker compose exec test-client ls /dicom/testdata/

# Store them into the PACS
docker compose exec test-client \
    storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/
```

### Creating Custom Test Data

Use `dump2dcm` to create DICOM files from text descriptions:

```bash
# Create a dump file
cat > data/my_test.dump << 'EOF'
(0002,0001) OB 00\01
(0002,0002) UI =CTImageStorage
(0002,0003) UI [1.2.3.999.1.1.1]
(0002,0010) UI =LittleEndianExplicit
(0010,0010) PN [CUSTOM^PATIENT]
(0010,0020) LO [CUST001]
(0010,0040) CS [F]
(0008,0020) DA [20260101]
(0008,0030) TM [080000]
(0008,0050) SH [ACC999]
(0008,0060) CS [CT]
(0020,000D) UI [1.2.3.999.1]
(0020,000E) UI [1.2.3.999.1.1]
(0020,0011) IS [1]
(0020,0013) IS [1]
(0008,0016) UI =CTImageStorage
(0008,0018) UI [1.2.3.999.1.1.1]
EOF

# Convert to DICOM
docker compose exec test-client \
    dump2dcm /dicom/testdata/my_test.dump /dicom/testdata/custom.dcm

# Verify
docker compose exec test-client dcmdump /dicom/testdata/custom.dcm
```

### Regenerating Test Data

```bash
# Remove existing generated data
rm -rf data/ct data/mr data/cr

# Restart test-client to regenerate
docker compose restart test-client
```

---

## 6. Configuration Reference

### Environment Variables (Complete List)

| Variable | Default | Used By | Description |
|----------|---------|---------|-------------|
| **Service Identity** | | | |
| `PACS1_AE_TITLE` | `DCMTK_PACS` | pacs-server | Primary PACS Application Entity Title |
| `PACS2_AE_TITLE` | `DCMTK_PAC2` | pacs-server-2 | Secondary PACS AE Title |
| `STORESCP_AE_TITLE` | `STORE_SCP` | storescp-receiver | Store SCP receiver AE Title |
| `TEST_SCU_AE_TITLE` | `TEST_SCU` | test-client | Test client AE Title |
| **Port Mapping** | | | |
| `PACS1_HOST_PORT` | `11112` | pacs-server | Host port for primary PACS |
| `PACS2_HOST_PORT` | `11113` | pacs-server-2 | Host port for secondary PACS |
| `STORESCP_HOST_PORT` | `11114` | storescp-receiver | Host port for store receiver |
| `DICOM_PORT` | `11112` | all | Internal container DICOM port |
| **PACS Tuning** | | | |
| `MAX_PDU_SIZE` | `16384` | PACS servers | Max Protocol Data Unit (4096-131072) |
| `MAX_ASSOCIATIONS` | `16` | PACS servers | Max concurrent DICOM associations |
| `MAX_STUDIES` | `200` | PACS servers | Max studies in storage area |
| `MAX_BYTES_PER_STUDY` | `1024mb` | PACS servers | Max storage per study |
| **Logging** | | | |
| `LOG_LEVEL` | `info` | all | DCMTK log level: debug, info, warn, error |
| **Test Data** | | | |
| `GENERATE_TEST_DATA` | `true` | pacs-server, test-client | Auto-generate synthetic DICOM files |
| `OID_ROOT` | `1.2.826.0.1.3680043.8.499` | generate-test-data.sh | OID root for test UIDs |

### dcmqrscp Configuration Template Syntax

Templates in `config/` use `${VARIABLE}` placeholders processed by `envsubst`.

**HostTable entry format:**
```
symbolic_name = (AETitle, hostname, port)
```

**AETable entry format:**
```
AETitle  StorageDirectory  AccessMode  (MaxStudies, MaxBytesPerStudy)  Peers
```

- `AccessMode`: `R` (read), `W` (write), `RW` (both)
- `Peers`: `ANY` (accept all) or a host group name from HostTable

### Volumes

| Volume | Mount Point | Purpose |
|--------|-------------|---------|
| `pacs-data` | `/dicom/db` (pacs-server) | Primary PACS storage |
| `pacs2-data` | `/dicom/db` (pacs-server-2) | Secondary PACS storage |
| `received-data` | `/dicom/received` (storescp-receiver) | C-MOVE received files |
| `./config` (bind) | `/etc/dcmtk` (PACS servers) | Config templates (read-only) |
| `./data` (bind) | `/dicom/testdata` (test-client) | Test DICOM files |
| `./tests` (bind) | `/tests` (test-client) | Test scripts (read-only) |

---

## 7. Advanced Scenarios

### Multi-PACS Forwarding

Store images in primary PACS, then move them to secondary:

```bash
# 1. Store to primary
storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/ct/

# 2. Move from primary to secondary
movescu -v -S -aet TEST_SCU -aec DCMTK_PACS -aem DCMTK_PAC2 \
    pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="DOE*"

# 3. Verify on secondary
findscu -v -S -aet TEST_SCU -aec DCMTK_PAC2 pacs-server-2 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="*" \
    -k StudyInstanceUID
```

### Stress Testing

```bash
# Repeated single-file store
storescu --repeat 100 -aet TEST_SCU -aec DCMTK_PACS \
    pacs-server 11112 /dicom/testdata/ct/ct_pat001_1.dcm

# Parallel stores (from host)
for i in $(seq 1 5); do
    docker compose exec -d test-client \
        storescu -aet "SCU_$i" -aec DCMTK_PACS \
        +sd +r pacs-server 11112 /dicom/testdata/ &
done
wait
```

### Using from CI/CD

```yaml
# Example GitHub Actions step
- name: Run PACS integration tests
  run: |
    cd dcmtk_docker
    ./pacs.sh up
    ./pacs.sh test
    ./pacs.sh clean
```

Or using `docker compose` directly (no `.env` copy needed thanks to `env_file` fallback):

```yaml
- name: Run PACS integration tests
  run: |
    cd dcmtk_docker
    docker compose up -d --build
    docker compose exec -T test-client /tests/test-all.sh
    docker compose down -v
```

### Custom Role

Run any DCMTK command as a one-off container:

```bash
# Run dcmdump on a file
docker compose run --rm -e ROLE=custom test-client \
    dcmdump /dicom/testdata/ct/ct_pat001_1.dcm

# Run a custom script
docker compose run --rm -e ROLE=custom test-client \
    bash -c "echoscu pacs-server 11112 && echo 'PACS is up'"
```

### TLS-Secured DICOM (DICOM TLS)

DCMTK 3.6.7 supports TLS for encrypted DICOM communication. This is not enabled
by default in this test environment but can be configured manually.

**Generating test certificates:**

```bash
# Enter test-client shell
docker compose exec test-client bash

# Generate a self-signed CA and server/client certificates
openssl req -x509 -newkey rsa:2048 -keyout ca-key.pem -out ca-cert.pem \
    -days 365 -nodes -subj "/CN=DICOM-Test-CA"

openssl req -newkey rsa:2048 -keyout server-key.pem -out server-csr.pem \
    -nodes -subj "/CN=pacs-server"
openssl x509 -req -in server-csr.pem -CA ca-cert.pem -CAkey ca-key.pem \
    -CAcreateserial -out server-cert.pem -days 365

openssl req -newkey rsa:2048 -keyout client-key.pem -out client-csr.pem \
    -nodes -subj "/CN=test-client"
openssl x509 -req -in client-csr.pem -CA ca-cert.pem -CAkey ca-key.pem \
    -CAcreateserial -out client-cert.pem -days 365
```

**Using TLS with DCMTK tools:**

```bash
# TLS-enabled C-ECHO
echoscu +tls client-key.pem client-cert.pem \
    --add-cert-file ca-cert.pem \
    -aet TEST_SCU -aec DCMTK_PACS pacs-server 2762

# TLS-enabled store receiver
storescp +tls server-key.pem server-cert.pem \
    --add-cert-file ca-cert.pem \
    -od /dicom/received 2762
```

Note: TLS requires a separate port (conventionally 2762 for DICOM TLS). The PACS
server itself (dcmqrscp) would need to be started with `+tls` flags — this requires
modifying the entrypoint script.

### Adding Additional PACS Nodes

To add a third PACS node, extend `docker-compose.yml`:

```yaml
# Add to docker-compose.yml under services:
pacs-server-3:
  build: .
  container_name: pacs-server-3
  environment:
    - ROLE=pacs-server
    - AE_TITLE=DCMTK_PAC3
    - DICOM_PORT=11112
    - STORAGE_DIR=/dicom/db
    - CONFIG_TEMPLATE=/etc/dcmtk/dcmqrscp-primary.cfg.template
    # Add other PACS nodes to this node's HostTable
    - PACS2_AE_TITLE=DCMTK_PAC2
    - STORESCP_AE_TITLE=STORE_SCP
    - TEST_SCU_AE_TITLE=TEST_SCU
  ports:
    - "11115:11112"
  volumes:
    - pacs3-data:/dicom/db
    - ./config:/etc/dcmtk:ro
  networks:
    - dicom-net
  healthcheck:
    test: ["CMD", "echoscu", "localhost", "11112"]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 10s

# Add under volumes:
# pacs3-data:
```

Then update the HostTable in the config templates to include the new node so
C-MOVE can route to it.

### Integration with External DICOM Servers

#### Connecting Orthanc

[Orthanc](https://www.orthanc-server.com/) is a lightweight DICOM server with a
REST API. To test interoperability:

```bash
# Start Orthanc alongside this environment
docker run -d --name orthanc \
    --network dcmtk_docker_dicom-net \
    -p 8042:8042 -p 4242:4242 \
    -e ORTHANC__DICOM_AET=ORTHANC \
    -e ORTHANC__DICOM_PORT=4242 \
    jodogne/orthanc

# Store from this PACS to Orthanc
docker compose exec test-client \
    storescu -v -aet TEST_SCU -aec ORTHANC orthanc 4242 /dicom/testdata/ct/

# Query Orthanc via C-FIND
docker compose exec test-client \
    findscu -v -S -aet TEST_SCU -aec ORTHANC orthanc 4242 \
    -k QueryRetrieveLevel=STUDY -k PatientName="*" -k StudyInstanceUID

# Verify via Orthanc REST API
curl http://localhost:8042/studies
```

#### Connecting dcm4chee-arc

For enterprise-grade PACS testing with [dcm4chee](https://github.com/dcm4che/dcm4chee-arc-light):

```bash
# dcm4chee typically runs on port 11112 — use a different host port
# Store from this environment to dcm4chee
docker compose exec test-client \
    storescu -v -aet TEST_SCU -aec DCM4CHEE \
    <dcm4chee-host> <dcm4chee-port> /dicom/testdata/
```

### Performance Tuning

#### MaxPDUSize

Controls the maximum Protocol Data Unit size for DICOM network communication.

| Value | Effect | Use Case |
|-------|--------|----------|
| `16384` (default) | Conservative, compatible | Standard testing |
| `65536` | Good balance | General purpose |
| `131072` | Maximum throughput | Bulk transfers, benchmarks |

```bash
# Set in .env
MAX_PDU_SIZE=65536
docker compose up -d --force-recreate
```

#### MaxAssociations

Controls how many concurrent DICOM connections dcmqrscp accepts.

| Value | Effect | Use Case |
|-------|--------|----------|
| `16` (default) | Moderate concurrency | Standard testing |
| `32` | Higher concurrency | Multi-client scenarios |
| `64` | Maximum concurrency | Stress testing |

Each association consumes memory. For stress testing, increase gradually and monitor
container memory usage with `docker stats`.

### CI/CD Integration Examples

#### GitHub Actions

```yaml
name: PACS Integration Tests

on: [push, pull_request]

jobs:
  pacs-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start PACS environment
        working-directory: dcmtk_docker
        run: ./pacs.sh up

      - name: Run DICOM tests
        working-directory: dcmtk_docker
        run: ./pacs.sh test

      - name: Collect logs on failure
        if: failure()
        working-directory: dcmtk_docker
        run: |
          docker compose logs > pacs-logs.txt
          ./pacs.sh status

      - name: Upload logs
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: pacs-logs
          path: dcmtk_docker/pacs-logs.txt

      - name: Cleanup
        if: always()
        working-directory: dcmtk_docker
        run: ./pacs.sh clean
```

#### GitLab CI

```yaml
pacs-integration:
  stage: test
  image: docker:24
  services:
    - docker:24-dind
  variables:
    DOCKER_HOST: tcp://docker:2376
    DOCKER_TLS_CERTDIR: "/certs"
  script:
    - cd dcmtk_docker
    - ./pacs.sh up
    - ./pacs.sh test
  after_script:
    - cd dcmtk_docker && ./pacs.sh clean
```

---

## 8. Troubleshooting Guide

### Quick Diagnosis

```bash
# 1. Are all containers running and healthy?
./pacs.sh status

# 2. Any errors in logs?
./pacs.sh logs

# 3. Can test-client reach PACS?
./pacs.sh echo localhost 11112

# 4. Is config correct?
docker compose exec pacs-server cat /tmp/dcmqrscp.cfg
```

### Common Issues

#### "Connection refused"

**Cause**: Service not running or wrong port.

```bash
# Check service status
docker compose ps pacs-server
# Should show "running (healthy)"

# Check the container is actually listening
docker compose exec pacs-server nc -zv localhost 11112
```

#### "Association rejected"

**Cause**: AE Title mismatch, or service not accepting connections.

```bash
# AE Titles are case-sensitive — verify exact match
docker compose exec pacs-server cat /tmp/dcmqrscp.cfg | grep AETable -A 5

# Try with verbose output
docker compose exec test-client \
    echoscu -d -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112
```

#### C-FIND returns 0 results

**Cause**: No data stored in PACS, or query keys don't match.

```bash
# Verify data is in PACS
docker compose exec pacs-server ls -la /dicom/db/DCMTK_PACS/

# Check if index.dat exists (dcmqrscp database)
docker compose exec pacs-server ls -la /dicom/db/DCMTK_PACS/index.dat

# Store test data manually
docker compose exec test-client \
    storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/
```

#### C-MOVE fails / destination unreachable

**Cause**: Destination AE not in HostTable, or destination not listening.

```bash
# Check HostTable configuration
docker compose exec pacs-server cat /tmp/dcmqrscp.cfg | grep -A 10 "HostTable"

# Verify destination is reachable from PACS server
docker compose exec pacs-server echoscu storescp-receiver 11112

# Check destination is listening
docker compose exec storescp-receiver nc -zv localhost 11112
```

#### Image build fails

```bash
# Clean build (no cache)
docker compose build --no-cache

# Check Docker disk space
docker system df
```

#### Port already in use

```bash
# Check what's using the port
lsof -i :11112

# Change port in .env
echo "PACS1_HOST_PORT=21112" >> .env
docker compose up -d
```

### Debug Mode

Enable maximum logging detail:

```bash
# Set debug log level in .env
echo "LOG_LEVEL=debug" >> .env

# Restart with debug
docker compose up -d --force-recreate pacs-server

# Watch debug output
docker compose logs -f pacs-server
```

For individual command debugging, add `-d` flag:

```bash
# Debug C-ECHO
docker compose exec test-client \
    echoscu -d -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112
```

---

## 9. Common Test Scenarios

### Scenario 1: Verify PACS Connectivity

```bash
# Test all SCP endpoints
./pacs.sh test echo
```

### Scenario 2: End-to-End Store and Query

```bash
# Store → Find → Verify
storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/ct/

findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="DOE*" \
    -k StudyDate \
    -k NumberOfStudyRelatedInstances \
    -k StudyInstanceUID
```

### Scenario 3: Full Store-Find-Move Workflow

```bash
# 1. Store images to PACS
storescu -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/

# 2. Find the stored study
findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientID="PAT001" \
    -k StudyInstanceUID

# 3. Move to storescp-receiver
movescu -v -S -aet TEST_SCU -aec DCMTK_PACS -aem STORE_SCP \
    pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k StudyInstanceUID="1.2.826.0.1.3680043.8.499.1.1"

# 4. Verify files received
docker compose exec storescp-receiver ls -la /dicom/received/
```

### Scenario 4: Test External Application Integration

```bash
# From the host machine (requires DCMTK installed locally)

# Connect to primary PACS
echoscu -v -aet MY_APP -aec DCMTK_PACS localhost 11112

# Store files
storescu -v -aet MY_APP -aec DCMTK_PACS localhost 11112 /path/to/file.dcm

# Query
findscu -v -S -aet MY_APP -aec DCMTK_PACS localhost 11112 \
    -k QueryRetrieveLevel=STUDY -k PatientName="*" -k StudyInstanceUID
```

### Scenario 5: Automated Test Suite

```bash
# Run all tests
./pacs.sh test

# Run specific suite
./pacs.sh test echo
./pacs.sh test store
./pacs.sh test find
./pacs.sh test move

# Expected output:
# ========================================
#   DCMTK PACS Test Suite
# ========================================
#   ...
#   Results: N/N passed, 0 failed
# ========================================
# RESULT: ALL TESTS PASSED
```

---

*Document generated: 2026-03-19 | For: dcmtk_docker project — Docker-based PACS test environment*
