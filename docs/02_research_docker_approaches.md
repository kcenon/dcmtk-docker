# Docker Approaches for DCMTK and PACS Test Environments

Research document covering existing Docker images, base image selection, installation approaches,
Docker Compose patterns, health checks, and test data strategies for DCMTK-based PACS environments.

---

## Table of Contents

1. [Existing DCMTK Docker Images](#1-existing-dcmtk-docker-images)
2. [Base Image Selection](#2-base-image-selection)
3. [DCMTK Installation in Docker](#3-dcmtk-installation-in-docker)
4. [Docker Compose Patterns for DICOM](#4-docker-compose-patterns-for-dicom)
5. [Health Checks and Monitoring](#5-health-checks-and-monitoring)
6. [Test Data](#6-test-data)
7. [Recommendations](#7-recommendations)

---

## 1. Existing DCMTK Docker Images

### Community Docker Images

| Image | Base | DCMTK Version | Last Updated | Size | Approach |
|-------|------|---------------|--------------|------|----------|
| `darthunix/dcmtk` | Alpine | 3.6.x | 2020 | ~30 MB | Build from source |
| `bastula/alpine-dcmtk` | Alpine | 3.6.x (GitHub mirror) | 2020 | ~30 MB | Build from source |
| `qiicr/docker-dcmtk-cli` | Unknown | 3.6.x | 2017 | Unknown | Build from source |
| `pydicom/dicom` | Ubuntu | 3.6.1-3.6.5 | Active | ~500 MB | Includes pydicom + pynetdicom |
| `vaper/dcmtk` | Unknown | Unknown | Unknown | Unknown | Unknown |
| `donilan/dcmtk` | Unknown | Unknown | Unknown | Unknown | Unknown |
| `spectronic/dcmtk` | Unknown | Unknown | Unknown | Unknown | Unknown |

### Related DICOM Server Docker Images

| Image | Type | Notes |
|-------|------|-------|
| `jodogne/orthanc` | Full PACS server | Lightweight, REST API, DICOMweb, plugins |
| `jodogne/orthanc-python` | Orthanc + Python plugin | Scripting support |
| `sparklyballs/pacs` | PACS setup | Community PACS container |
| `dcm4che/dcm4chee-arc-psql` | DCM4CHEE Archive | Enterprise-grade, PostgreSQL-backed |

### Evaluation

**darthunix/dcmtk & bastula/alpine-dcmtk**
- Pros: Lightweight Alpine base, minimal image size
- Cons: Not actively maintained (last update 2020), outdated DCMTK versions
- Use case: Reference for Alpine-based build approach

**qiicr/docker-dcmtk-cli**
- Pros: Includes 45+ DCMTK command-line tools, entry point script
- Cons: Dormant since 2017, very outdated
- Use case: Reference for tool bundling pattern

**pydicom/dicom**
- Pros: Actively maintained, includes Python DICOM tools, version matrix
- Cons: Large image (~500 MB), includes unnecessary Python stack for pure DCMTK use
- Use case: Good reference for versioned builds, useful if Python DICOM tools needed

**jodogne/orthanc**
- Pros: Production-ready PACS, REST API, extensive plugin ecosystem, well-documented
- Cons: Not DCMTK-based (uses its own C++ DICOM implementation), heavier
- Use case: Alternative PACS server for integration testing

### Key Insight

Most existing DCMTK Docker images are **outdated** (targeting DCMTK 3.6.x while 3.7.0 is current).
Building a fresh image is the recommended approach for a modern DCMTK environment.

---

## 2. Base Image Selection

### DCMTK Version Availability

| Distribution | Package Version | DCMTK Latest |
|--------------|----------------|---------------|
| Debian Bookworm (12) | 3.6.7-9~deb12u3 | 3.7.0 (Dec 2025) |
| Ubuntu 24.04 (Noble) | 3.6.7-9.1build4 | 3.7.0 (Dec 2025) |
| Alpine 3.20 | Available via `apk` (community) | 3.7.0 (Dec 2025) |

**Note**: Distribution packages lag significantly behind the latest DCMTK release (3.6.7 vs 3.7.0).
For the latest version, building from source is required.

### Base Image Comparison

| Criteria | Ubuntu 24.04 | Debian Bookworm | Alpine 3.20 |
|----------|-------------|-----------------|-------------|
| Base image size | ~78 MB | ~52 MB | ~7 MB |
| Package manager | apt | apt | apk |
| DCMTK via package | 3.6.7 | 3.6.7 | Community repo |
| Build from source | Easy (all deps available) | Easy (all deps available) | Possible (musl libc caveats) |
| C++ compiler | gcc 13.2+ | gcc 12.2+ | gcc 13+ |
| CMake availability | Yes (apt) | Yes (apt) | Yes (apk) |
| Debug tooling | Excellent | Excellent | Limited |
| Final image size (apt) | ~200 MB | ~170 MB | ~50 MB |
| Final image size (source) | ~150 MB (multi-stage) | ~120 MB (multi-stage) | ~30 MB (multi-stage) |
| Shell | bash | bash | ash (BusyBox) |
| glibc/musl | glibc | glibc | musl libc |
| DCMTK forum reports | Fully tested | Fully tested | Works, some historical quirks |

### Alpine-Specific Considerations

- DCMTK compiles successfully on Alpine 3.20 (confirmed in DCMTK install docs)
- Uses musl libc instead of glibc -- generally fine for DCMTK but may cause subtle issues
- Smaller images but harder to debug (no standard coreutils, ash shell)
- Historical compilation issues have been resolved in recent Alpine/DCMTK versions
- BusyBox utilities differ from GNU utilities in edge cases

### Recommendation

**For development/testing**: Debian Bookworm (slim variant)
- Good balance of size and tooling
- apt package for quick setup, source build for latest version
- Familiar debugging environment

**For production/minimal images**: Alpine with multi-stage build
- Smallest final image
- Multi-stage build eliminates build dependencies

---

## 3. DCMTK Installation in Docker

### Approach A: Package Manager (Quick, Older Version)

```dockerfile
# Debian/Ubuntu approach
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    dcmtk \
    && rm -rf /var/lib/apt/lists/*

# Installs DCMTK 3.6.7 with all command-line tools
# Tools available: storescu, storescp, echoscu, findscu, movescu, dump2dcm, dcmdump, etc.
```

**Pros**: Simple, fast build, well-tested package
**Cons**: Older version (3.6.7), no customization, includes dev libraries

### Approach B: Build from Source (Latest Version, Full Control)

```dockerfile
# Multi-stage build for DCMTK 3.7.0
FROM debian:bookworm-slim AS builder

ARG DCMTK_VERSION=3.7.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libxml2-dev \
    libssl-dev \
    libpng-dev \
    libtiff-dev \
    libwrap0-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone and build DCMTK
RUN git clone --branch DCMTK-${DCMTK_VERSION} --depth 1 \
    https://github.com/DCMTK/dcmtk.git /src/dcmtk

WORKDIR /src/dcmtk/build

RUN cmake .. \
    -DCMAKE_INSTALL_PREFIX=/opt/dcmtk \
    -DCMAKE_BUILD_TYPE=Release \
    -DDCMTK_WITH_OPENSSL=ON \
    -DDCMTK_WITH_PNG=ON \
    -DDCMTK_WITH_TIFF=ON \
    -DDCMTK_WITH_XML=ON \
    -DDCMTK_WITH_ZLIB=ON \
    -DDCMTK_WITH_ICONV=ON \
    -DBUILD_SHARED_LIBS=ON \
    && make -j$(nproc) \
    && make install

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2 \
    libssl3 \
    libpng16-16 \
    libtiff6 \
    libwrap0 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/dcmtk /opt/dcmtk

ENV PATH="/opt/dcmtk/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/dcmtk/lib:${LD_LIBRARY_PATH}"
```

**Pros**: Latest version (3.7.0), customizable features, smaller runtime image
**Cons**: Longer build time (~5-10 min), more complex Dockerfile

### Approach C: Alpine Multi-Stage (Smallest Image)

```dockerfile
FROM alpine:3.20 AS builder

ARG DCMTK_VERSION=3.7.0

RUN apk add --no-cache \
    build-base \
    cmake \
    git \
    libxml2-dev \
    openssl-dev \
    libpng-dev \
    tiff-dev \
    zlib-dev

RUN git clone --branch DCMTK-${DCMTK_VERSION} --depth 1 \
    https://github.com/DCMTK/dcmtk.git /src/dcmtk

WORKDIR /src/dcmtk/build

RUN cmake .. \
    -DCMAKE_INSTALL_PREFIX=/opt/dcmtk \
    -DCMAKE_BUILD_TYPE=Release \
    -DDCMTK_WITH_OPENSSL=ON \
    -DDCMTK_WITH_XML=ON \
    -DDCMTK_WITH_ZLIB=ON \
    -DBUILD_SHARED_LIBS=OFF \
    && make -j$(nproc) \
    && make install

FROM alpine:3.20

RUN apk add --no-cache \
    libxml2 \
    libssl3 \
    libpng \
    tiff \
    zlib \
    libstdc++

COPY --from=builder /opt/dcmtk /opt/dcmtk

ENV PATH="/opt/dcmtk/bin:${PATH}"
```

**Pros**: Smallest image (~30-50 MB), static linking option
**Cons**: musl libc, limited debug tools, ash shell

### Build Dependencies Reference

| Dependency | Purpose | Debian Package | Alpine Package |
|-----------|---------|---------------|----------------|
| CMake | Build system | `cmake` | `cmake` |
| GCC/G++ | Compiler | `build-essential` | `build-base` |
| OpenSSL | TLS support | `libssl-dev` / `libssl3` | `openssl-dev` / `libssl3` |
| libxml2 | XML support | `libxml2-dev` / `libxml2` | `libxml2-dev` / `libxml2` |
| zlib | Compression | `zlib1g-dev` / `zlib1g` | `zlib-dev` / `zlib` |
| libpng | PNG support | `libpng-dev` / `libpng16-16` | `libpng-dev` / `libpng` |
| libtiff | TIFF support | `libtiff-dev` / `libtiff6` | `tiff-dev` / `tiff` |
| TCP Wrappers | Access control | `libwrap0-dev` / `libwrap0` | N/A (Alpine) |

---

## 4. Docker Compose Patterns for DICOM

### Pattern 1: Single PACS Server (Minimal)

```yaml
version: "3.8"

services:
  pacs:
    build: .
    ports:
      - "11112:11112"   # DICOM port
    environment:
      - AE_TITLE=DCMTK_PACS
      - DICOM_PORT=11112
      - STORAGE_DIR=/dicom/storage
    volumes:
      - dicom-storage:/dicom/storage
    healthcheck:
      test: ["CMD", "echoscu", "localhost", "11112"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s

volumes:
  dicom-storage:
```

### Pattern 2: PACS + Client (Testing Pair)

```yaml
version: "3.8"

services:
  pacs-server:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: pacs-server
    ports:
      - "11112:11112"
    environment:
      - AE_TITLE=PACS_SCP
      - DICOM_PORT=11112
    volumes:
      - dicom-storage:/dicom/storage
    networks:
      - dicom-net
    healthcheck:
      test: ["CMD", "echoscu", "localhost", "11112"]
      interval: 10s
      timeout: 5s
      retries: 3

  pacs-client:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: pacs-client
    depends_on:
      pacs-server:
        condition: service_healthy
    environment:
      - PACS_HOST=pacs-server
      - PACS_PORT=11112
      - PACS_AE_TITLE=PACS_SCP
      - MY_AE_TITLE=PACS_SCU
    volumes:
      - test-data:/dicom/testdata
      - query-results:/dicom/results
    networks:
      - dicom-net

networks:
  dicom-net:
    driver: bridge

volumes:
  dicom-storage:
  test-data:
  query-results:
```

### Pattern 3: Multi-PACS Network (Advanced)

```yaml
version: "3.8"

services:
  # Primary PACS (storage + query/retrieve)
  pacs-primary:
    build: .
    container_name: pacs-primary
    ports:
      - "11112:11112"
    environment:
      - AE_TITLE=PRIMARY
      - DICOM_PORT=11112
    volumes:
      - primary-storage:/dicom/storage
    networks:
      - dicom-net

  # Secondary PACS (receives forwarded studies)
  pacs-secondary:
    build: .
    container_name: pacs-secondary
    ports:
      - "11113:11112"
    environment:
      - AE_TITLE=SECONDARY
      - DICOM_PORT=11112
    volumes:
      - secondary-storage:/dicom/storage
    networks:
      - dicom-net

  # Test runner with DICOM tools
  test-runner:
    build: .
    container_name: test-runner
    depends_on:
      pacs-primary:
        condition: service_healthy
      pacs-secondary:
        condition: service_healthy
    volumes:
      - ./tests:/tests
      - ./test-data:/dicom/testdata
    networks:
      - dicom-net
    entrypoint: ["/bin/sh", "-c", "sleep infinity"]

networks:
  dicom-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16

volumes:
  primary-storage:
  secondary-storage:
```

### Docker Networking for DICOM

DICOM uses TCP connections for all communication. Key networking considerations:

| Aspect | Configuration | Notes |
|--------|--------------|-------|
| Protocol | TCP only | DICOM does not use UDP |
| Default port | 11112 | Standard DICOM port (configurable) |
| Bridge network | Recommended | Containers resolve each other by service name |
| Port exposure | Map host:container | Only expose to host if external access needed |
| AE Title resolution | By hostname | Container name = hostname in bridge network |
| Firewall | None within bridge | Docker bridge allows all internal traffic |

### Environment Variable Patterns

```yaml
environment:
  # Server configuration
  - AE_TITLE=MY_PACS          # Application Entity Title (max 16 chars)
  - DICOM_PORT=11112           # Listening port
  - STORAGE_DIR=/dicom/storage # Where received files are stored
  - MAX_PDU_SIZE=16384         # Maximum Protocol Data Unit size

  # Known peers (for C-MOVE destination lookup)
  - PEER_AE_TITLE=OTHER_PACS
  - PEER_HOST=pacs-secondary
  - PEER_PORT=11112

  # Logging
  - LOG_LEVEL=info             # debug, info, warn, error
```

### Volume Management

```yaml
volumes:
  # Named volumes for persistence across container restarts
  dicom-storage:
    driver: local

  # Bind mounts for test data and scripts
  # These allow host-side editing and inspection
  test-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ./test-data
```

### Startup Ordering

Docker Compose `depends_on` with `condition: service_healthy` ensures DICOM services
are ready before clients attempt connections. Without health checks, use startup scripts
with retry logic:

```bash
#!/bin/bash
# wait-for-pacs.sh
MAX_RETRIES=30
RETRY_INTERVAL=2

for i in $(seq 1 $MAX_RETRIES); do
    if echoscu "$PACS_HOST" "$PACS_PORT" 2>/dev/null; then
        echo "PACS server is ready"
        exit 0
    fi
    echo "Waiting for PACS server... ($i/$MAX_RETRIES)"
    sleep $RETRY_INTERVAL
done

echo "ERROR: PACS server not ready after $((MAX_RETRIES * RETRY_INTERVAL))s"
exit 1
```

---

## 5. Health Checks and Monitoring

### C-ECHO as Docker Health Check

The DICOM Verification Service (C-ECHO) is the standard way to check DICOM service availability.
DCMTK's `echoscu` tool sends a C-ECHO request and reports the result.

```dockerfile
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=5s \
    CMD echoscu localhost 11112 || exit 1
```

### Health Check Options

| Method | Command | Pros | Cons |
|--------|---------|------|------|
| C-ECHO | `echoscu localhost 11112` | Full DICOM verification | Requires echoscu binary |
| TCP check | `nc -z localhost 11112` | No DICOM dependency | Only checks TCP, not DICOM |
| Process check | `pgrep storescp` | Lightweight | Process may be alive but unresponsive |
| HTTP (Orthanc) | `curl -f http://localhost:8042/` | REST API check | Only for HTTP-enabled servers |

**Recommendation**: Use C-ECHO for DCMTK containers. It verifies the full DICOM protocol stack,
not just TCP connectivity.

### Service Readiness Detection

For Docker Compose `depends_on` with health checks:

```yaml
services:
  pacs:
    healthcheck:
      test: ["CMD", "echoscu", "localhost", "11112"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s  # Allow storescp to initialize

  client:
    depends_on:
      pacs:
        condition: service_healthy
```

### Log Management

```yaml
services:
  pacs:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    # storescp verbose logging
    command: >
      storescp --verbose
      --log-level info
      --output-directory /dicom/storage
      11112
```

DCMTK tools support log levels: `trace`, `debug`, `info`, `warn`, `error`, `fatal`.
Use `--verbose` or `--debug` during development, `--log-level info` for production.

### Monitoring Pattern

```bash
#!/bin/bash
# monitor.sh - Simple PACS monitoring script

check_pacs() {
    local host=$1
    local port=$2
    local ae_title=$3

    if echoscu -aet MONITOR -aec "$ae_title" "$host" "$port" 2>/dev/null; then
        echo "[OK] $ae_title at $host:$port"
        return 0
    else
        echo "[FAIL] $ae_title at $host:$port"
        return 1
    fi
}

check_pacs pacs-primary 11112 PRIMARY
check_pacs pacs-secondary 11112 SECONDARY
```

---

## 6. Test Data

### Sources for Sample DICOM Files

| Source | URL | Description | License |
|--------|-----|-------------|---------|
| TCIA | https://www.cancerimagingarchive.net/ | Large medical imaging archive | CC BY / varies |
| Rubo Medical | https://www.rubomedical.com/dicom_files/ | Small sample DICOM sets | Free |
| OsiriX Library | https://www.osirix-viewer.com/resources/dicom-image-library/ | CT, MR, PET sample datasets | Free |
| Medimodel | https://medimodel.com/sample-dicom-files/ | Anonymized CT/MRI scans | Free |
| Aliza Datasets | https://www.aliza-dicom-viewer.com/download/datasets | Various modality samples | Free |
| 3Dicom Library | https://3dicomviewer.com/dicom-library/ | Free research datasets | Free |

### Creating Synthetic DICOM Files with dump2dcm

`dump2dcm` converts ASCII text descriptions to DICOM files. This is ideal for creating
lightweight test data without downloading large imaging datasets.

#### Minimal DICOM File Template

```
# minimal_ct.txt - Minimal CT Image for testing

# Meta Information
(0002,0001) OB 00\01                          # FileMetaInformationVersion
(0002,0002) UI =CTImageStorage                # MediaStorageSOPClassUID
(0002,0003) UI [1.2.3.4.5.6.7.8.9.1]         # MediaStorageSOPInstanceUID
(0002,0010) UI =LittleEndianExplicit          # TransferSyntaxUID

# Patient Module
(0010,0010) PN [TEST^PATIENT]                 # PatientName
(0010,0020) LO [TEST001]                      # PatientID
(0010,0030) DA [19800101]                     # PatientBirthDate
(0010,0040) CS [M]                            # PatientSex

# General Study Module
(0008,0020) DA [20240101]                     # StudyDate
(0008,0030) TM [120000]                       # StudyTime
(0008,0050) SH [ACC001]                       # AccessionNumber
(0008,0060) CS [CT]                           # Modality
(0020,000D) UI [1.2.3.4.5.6.7.8.9.2]         # StudyInstanceUID
(0020,0010) SH [STUDY001]                     # StudyID

# General Series Module
(0020,000E) UI [1.2.3.4.5.6.7.8.9.3]         # SeriesInstanceUID
(0020,0011) IS [1]                            # SeriesNumber

# SOP Common Module
(0008,0016) UI =CTImageStorage                # SOPClassUID
(0008,0018) UI [1.2.3.4.5.6.7.8.9.1]         # SOPInstanceUID
```

#### Creating the DICOM File

```bash
# Create a single DICOM file from dump
dump2dcm minimal_ct.txt test_ct.dcm

# Verify the created file
dcmdump test_ct.dcm

# Create multiple test files with unique UIDs
for i in $(seq 1 10); do
    sed "s/9\.1]/9.$i]/" minimal_ct.txt | \
    sed "s/TEST001/TEST$(printf '%03d' $i)/" > /tmp/test_$i.txt
    dump2dcm /tmp/test_$i.txt test_ct_$i.dcm
done
```

#### Other DCMTK Tools for Test Data

| Tool | Purpose | Example |
|------|---------|---------|
| `dump2dcm` | ASCII dump to DICOM | `dump2dcm input.txt output.dcm` |
| `img2dcm` | Standard image to DICOM | `img2dcm photo.jpg output.dcm` |
| `dcmodify` | Modify DICOM attributes | `dcmodify -m "PatientName=TEST" file.dcm` |
| `dcmcrle` | Apply RLE compression | `dcmcrle input.dcm output.dcm` |
| `dcmcjpeg` | Apply JPEG compression | `dcmcjpeg input.dcm output.dcm` |

### Test Data Generation Script

```bash
#!/bin/bash
# generate_test_data.sh - Create synthetic DICOM test dataset

OUTPUT_DIR="${1:-/dicom/testdata}"
mkdir -p "$OUTPUT_DIR"

# Generate a set of CT images for one patient
generate_patient_study() {
    local patient_name=$1
    local patient_id=$2
    local study_uid=$3
    local series_uid=$4
    local num_slices=${5:-5}

    for slice in $(seq 1 "$num_slices"); do
        local sop_uid="${study_uid}.$slice"
        local instance_num=$slice

        cat > "/tmp/dicom_${patient_id}_${slice}.txt" << DUMP
(0002,0001) OB 00\\01
(0002,0002) UI =CTImageStorage
(0002,0003) UI [$sop_uid]
(0002,0010) UI =LittleEndianExplicit
(0010,0010) PN [$patient_name]
(0010,0020) LO [$patient_id]
(0010,0040) CS [O]
(0008,0020) DA [20240101]
(0008,0030) TM [120000]
(0008,0050) SH [ACC_${patient_id}]
(0008,0060) CS [CT]
(0020,000D) UI [$study_uid]
(0020,0010) SH [STUDY_${patient_id}]
(0020,000E) UI [$series_uid]
(0020,0011) IS [1]
(0020,0013) IS [$instance_num]
(0008,0016) UI =CTImageStorage
(0008,0018) UI [$sop_uid]
DUMP

        dump2dcm "/tmp/dicom_${patient_id}_${slice}.txt" \
            "$OUTPUT_DIR/${patient_id}_${slice}.dcm"
    done
}

# Generate test patients
generate_patient_study "DOE^JOHN"   "P001" "1.2.3.100.1" "1.2.3.100.1.1" 5
generate_patient_study "SMITH^JANE" "P002" "1.2.3.100.2" "1.2.3.100.2.1" 3
generate_patient_study "TEST^DATA"  "P003" "1.2.3.100.3" "1.2.3.100.3.1" 1

echo "Generated test DICOM files in $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
```

### DICOM File Format Basics for Test Data

A DICOM file consists of:

1. **Preamble** (128 bytes of zeros) + magic bytes `DICM`
2. **File Meta Information** (Group 0002) - Transfer syntax, media storage
3. **Data Elements** - Tag (group,element) + VR + Length + Value

Key tags for test data:

| Tag | Name | Required | Example |
|-----|------|----------|---------|
| (0008,0016) | SOPClassUID | Yes | `1.2.840.10008.5.1.4.1.1.2` (CT) |
| (0008,0018) | SOPInstanceUID | Yes | Unique per file |
| (0008,0060) | Modality | Yes | CT, MR, US, XA, etc. |
| (0010,0010) | PatientName | Yes | `LAST^FIRST` |
| (0010,0020) | PatientID | Yes | Unique per patient |
| (0020,000D) | StudyInstanceUID | Yes | Unique per study |
| (0020,000E) | SeriesInstanceUID | Yes | Unique per series |

**Important**: SOPInstanceUID must be globally unique. For test data, use a private OID root
(e.g., `1.2.3.999.xxx`) to avoid collision with real clinical data.

---

## 7. Recommendations

### Recommended Architecture

Based on this research, the recommended approach for a DCMTK Docker PACS test environment:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Base image | `debian:bookworm-slim` | Balance of size, tooling, and compatibility |
| DCMTK version | 3.6.7 (apt) initially, 3.7.0 (source) as option | Quick start with apt, upgrade path via source |
| Build approach | Multi-stage with apt for primary, source build as option | Flexibility without complexity |
| Compose pattern | PACS server + client pair with health checks | Covers C-STORE, C-ECHO, C-FIND, C-MOVE testing |
| Health check | C-ECHO via echoscu | Full DICOM protocol verification |
| Test data | Synthetic via dump2dcm | No external dependencies, customizable |
| Networking | Docker bridge network | Service name resolution, isolation |

### Image Structure

```
dcmtk-pacs/
  Dockerfile           # Multi-stage: builder + runtime
  docker-compose.yml   # PACS server + client + test runner
  config/
    storescp.cfg       # Storage SCP configuration
    dcmqrscp.cfg       # Query/Retrieve SCP configuration
  scripts/
    entrypoint.sh      # Container entrypoint with role selection
    wait-for-pacs.sh   # Readiness check script
    generate-data.sh   # Synthetic DICOM test data generation
  test-data/
    templates/         # dump2dcm template files
  tests/
    test_store.sh      # C-STORE tests
    test_echo.sh       # C-ECHO tests
    test_find.sh       # C-FIND tests
    test_move.sh       # C-MOVE tests
```

### Key Design Decisions

1. **Single image, multiple roles**: Use the same Docker image for both SCP (server) and SCU (client)
   by switching the entrypoint command. This simplifies builds and ensures tool version consistency.

2. **storescp for basic storage + dcmqrscp for query/retrieve**: storescp handles C-STORE
   and C-ECHO; dcmqrscp adds C-FIND and C-MOVE capabilities.

3. **Environment-based configuration**: All settings (AE title, port, storage directory)
   configurable via environment variables for Docker Compose flexibility.

4. **Synthetic test data**: Generate DICOM files at container startup using dump2dcm,
   avoiding external data dependencies and licensing concerns.

---

## References

### DCMTK Official
- [DCMTK GitHub Mirror](https://github.com/DCMTK/dcmtk)
- [DCMTK 3.7.0 Release](https://support.dcmtk.org/redmine/news/23)
- [DCMTK Installation Guide](https://support.dcmtk.org/docs/file_install.html)
- [storescp Documentation](https://support.dcmtk.org/docs/storescp.html)
- [echoscu Documentation](https://support.dcmtk.org/docs/echoscu.html)
- [dump2dcm Documentation](https://support.dcmtk.org/docs/dump2dcm.html)
- [DCMTK DeepWiki - Installation](https://deepwiki.com/DCMTK/dcmtk/2-installation-and-build-system)
- [DCMTK Forum - Alpine Compilation](https://forum.dcmtk.org/viewtopic.php?t=4564)

### Docker Images
- [darthunix/dcmtk](https://hub.docker.com/r/darthunix/dcmtk) - Alpine-based DCMTK
- [bastula/alpine-dcmtk](https://github.com/bastula/alpine-dcmtk) - Alpine DCMTK build
- [QIICR/docker-dcmtk-cli](https://github.com/QIICR/docker-dcmtk-cli) - DCMTK CLI Docker
- [pydicom/dicom-containers](https://github.com/pydicom/dicom-containers) - Pydicom + DCMTK
- [jodogne/orthanc](https://hub.docker.com/r/jodogne/orthanc/) - Orthanc DICOM Server
- [orthanc-server/orthanc-setup-samples](https://github.com/orthanc-server/orthanc-setup-samples) - Orthanc Docker Compose samples

### Distribution Packages
- [Debian DCMTK Package](https://packages.debian.org/stable/dcmtk)
- [Ubuntu DCMTK Package](https://launchpad.net/ubuntu/+source/dcmtk)
- [Repology DCMTK Versions](https://repology.org/project/dcmtk/versions)

### Test Data
- [The Cancer Imaging Archive (TCIA)](https://www.cancerimagingarchive.net/)
- [Rubo Medical Sample DICOM Files](https://www.rubomedical.com/dicom_files/)
- [OsiriX DICOM Library](https://www.osirix-viewer.com/resources/dicom-image-library/)
- [Medimodel Sample Files](https://medimodel.com/sample-dicom-files/)

### Docker Best Practices
- [Docker Multi-Stage Builds](https://docs.docker.com/get-started/docker-concepts/building-images/multi-stage-builds/)
- [Docker Build Best Practices](https://docs.docker.com/build/building/best-practices/)
- [DICOM Health Check (loadbalancer.org)](https://www.loadbalancer.org/blog/load-balancing-dicom-pacs-health-check/)
