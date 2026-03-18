# DCMTK PACS Test Environment

A Docker-based PACS integration test environment using DCMTK.
Start a complete DICOM network with a single command.

## Quick Start

```bash
# 1. Copy default configuration
cp env.default .env

# 2. Build and start all services
docker compose up -d --build

# 3. Run the full test suite
docker compose exec test-client /tests/test-all.sh
```

All DICOM operations (C-ECHO, C-STORE, C-FIND, C-MOVE) are tested automatically.

## Architecture

```
Host Machine
┌──────────────────────────────────────────────────────────┐
│ Docker Network: dicom-net                                │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ pacs-server  │  │ pacs-server-2│  │ storescp-     │  │
│  │ (dcmqrscp)   │  │ (dcmqrscp)   │  │ receiver      │  │
│  │ AE:DCMTK_PACS│  │ AE:DCMTK_PAC2│  │ AE:STORE_SCP  │  │
│  │ :11112       │  │ :11112       │  │ :11112        │  │
│  └──────┬───────┘  └──────────────┘  └───────────────┘  │
│         │ C-ECHO/STORE/FIND/MOVE                         │
│  ┌──────┴───────┐                                        │
│  │ test-client  │                                        │
│  │ (SCU tools)  │                                        │
│  │ AE:TEST_SCU  │                                        │
│  └──────────────┘                                        │
└──────────────────────────────────────────────────────────┘
  Host ports:  :11112  :11113  :11114
```

## Services

| Service | AE Title | Host Port | Role | Process |
|---------|----------|-----------|------|---------|
| pacs-server | `DCMTK_PACS` | 11112 | Primary PACS (C-ECHO, C-STORE, C-FIND, C-MOVE) | `dcmqrscp` |
| pacs-server-2 | `DCMTK_PAC2` | 11113 | Secondary PACS for multi-PACS testing | `dcmqrscp` |
| storescp-receiver | `STORE_SCP` | 11114 | C-MOVE destination / standalone receiver | `storescp` |
| test-client | `TEST_SCU` | — | Interactive SCU tool container | `sleep infinity` |

All services use a single Docker image (`debian:bookworm-slim` + DCMTK 3.6.7).
The `ROLE` environment variable selects which service to run.

## Usage

### Start and Stop

```bash
# Start all services
docker compose up -d

# Start specific services only
docker compose up -d pacs-server test-client

# View logs
docker compose logs -f pacs-server

# Stop all services (keep data)
docker compose down

# Stop and remove all data
docker compose down -v
```

### C-ECHO (Connectivity Test)

```bash
# From test-client container
docker compose exec test-client \
    echoscu -v -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112

# From host (requires DCMTK installed locally)
echoscu -v -aet MY_SCU -aec DCMTK_PACS localhost 11112
```

### C-STORE (Send Images)

```bash
# Store test data to primary PACS
docker compose exec test-client \
    storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/

# Store a single file
docker compose exec test-client \
    storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    pacs-server 11112 /dicom/testdata/ct/ct_pat001_1.dcm

# Store from host to PACS (requires DCMTK locally)
storescu -v -aet MY_SCU -aec DCMTK_PACS localhost 11112 /path/to/file.dcm
```

### C-FIND (Query)

```bash
# Find all studies
docker compose exec test-client \
    findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="*" \
    -k PatientID \
    -k StudyDate \
    -k StudyDescription \
    -k ModalitiesInStudy \
    -k StudyInstanceUID

# Find studies for a specific patient
docker compose exec test-client \
    findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k PatientName="DOE*" \
    -k StudyInstanceUID

# Find series within a study
docker compose exec test-client \
    findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=SERIES \
    -k StudyInstanceUID="1.2.826.0.1.3680043.8.499.1.1" \
    -k SeriesInstanceUID \
    -k Modality \
    -k SeriesDescription
```

### C-MOVE (Retrieve)

C-MOVE sends images from the PACS to a registered destination.
The destination (storescp-receiver, AE: `STORE_SCP`) is pre-configured in the
PACS HostTable.

```bash
# Retrieve a study to storescp-receiver
docker compose exec test-client \
    movescu -v -S -aet TEST_SCU -aec DCMTK_PACS -aem STORE_SCP \
    pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY \
    -k StudyInstanceUID="1.2.826.0.1.3680043.8.499.1.1"

# Check what storescp-receiver received
docker compose exec storescp-receiver ls -la /dicom/received/
```

### Interactive Shell

```bash
# Open a shell in the test-client container
docker compose exec test-client bash

# All DCMTK tools are available:
# echoscu, storescu, findscu, movescu, getscu,
# dcmdump, dump2dcm, dcmodify, dcmconv, img2dcm, dcmqridx
```

### Connect External DICOM Application

Any DICOM-capable application can connect to the PACS via the host-mapped ports:

| Parameter | Value |
|-----------|-------|
| Host | `<docker-host-ip>` or `localhost` |
| Port | `11112` (primary), `11113` (secondary) |
| Called AE Title | `DCMTK_PACS` or `DCMTK_PAC2` |
| Calling AE Title | Any (Peers = ANY) |

For C-MOVE **from** the PACS **to** an external application, the application must be
registered in the dcmqrscp HostTable. Edit `config/dcmqrscp-primary.cfg.template`
to add the external peer:

```
HostTable BEGIN
  ...
  my_viewer  = (VIEWER_AE, host.docker.internal, 4242)
  all_peers  = test_client, store_scp, pacs2, my_viewer
HostTable END
```

Then rebuild: `docker compose up -d --build pacs-server`

## Test Suite

### Run All Tests

```bash
docker compose exec test-client /tests/test-all.sh
```

### Run Individual Tests

```bash
docker compose exec test-client /tests/test-echo.sh    # Connectivity
docker compose exec test-client /tests/test-store.sh   # Image archival
docker compose exec test-client /tests/test-find.sh    # Query
docker compose exec test-client /tests/test-move.sh    # Retrieval
```

### Test Data

Synthetic DICOM files are generated automatically at first startup:

| Patient | PatientID | Modality | Series | Instances | Study Description |
|---------|-----------|----------|--------|-----------|-------------------|
| DOE^JOHN | PAT001 | CT | 1 | 5 | CT Abdomen |
| SMITH^JANE | PAT002 | MR | 2 (T1, T2) | 6 | MR Brain |
| WANG^LEI | PAT003 | CR | 1 | 2 | Chest PA |

To add custom DICOM files, place them in the `data/` directory.
They will be available in the test-client at `/dicom/testdata/`.

To regenerate test data, remove existing files and restart:

```bash
rm -rf data/ct data/mr data/cr
docker compose restart test-client
```

## Configuration

### Environment Variables

Copy `env.default` to `.env` and edit:

```bash
cp env.default .env
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PACS1_AE_TITLE` | `DCMTK_PACS` | Primary PACS AE Title |
| `PACS1_HOST_PORT` | `11112` | Primary PACS host port |
| `PACS2_AE_TITLE` | `DCMTK_PAC2` | Secondary PACS AE Title |
| `PACS2_HOST_PORT` | `11113` | Secondary PACS host port |
| `STORESCP_AE_TITLE` | `STORE_SCP` | Store SCP receiver AE Title |
| `STORESCP_HOST_PORT` | `11114` | Store SCP receiver host port |
| `TEST_SCU_AE_TITLE` | `TEST_SCU` | Test client AE Title |
| `DICOM_PORT` | `11112` | Internal container DICOM port |
| `MAX_PDU_SIZE` | `16384` | Maximum PDU size (bytes) |
| `MAX_ASSOCIATIONS` | `16` | Maximum concurrent associations |
| `MAX_STUDIES` | `200` | Maximum studies per storage area |
| `MAX_BYTES_PER_STUDY` | `1024mb` | Maximum bytes per study |
| `LOG_LEVEL` | `info` | Log level: debug, info, warn, error |
| `GENERATE_TEST_DATA` | `true` | Generate synthetic data on startup |
| `OID_ROOT` | `1.2.826.0.1.3680043.8.499` | OID root for test UIDs |

### dcmqrscp Configuration

The PACS servers use `dcmqrscp.cfg` templates in `config/`. Templates use `${VARIABLE}`
placeholders processed by `envsubst` at container startup.

- `config/dcmqrscp-primary.cfg.template` — Primary PACS config
- `config/dcmqrscp-secondary.cfg.template` — Secondary PACS config

Key sections:
- **HostTable**: Defines known peers for C-MOVE destination routing
- **AETable**: Defines storage areas, access mode, and capacity limits
- **Global**: Network port, PDU size, max associations

## Project Structure

```
dcmtk_docker/
├── Dockerfile                          # Single image: debian:bookworm-slim + DCMTK
├── docker-compose.yml                  # 4 services, 1 network, 3 volumes
├── env.default                         # Default environment values (copy to .env)
├── .dockerignore                       # Build context exclusions
├── README.md                           # This file
├── config/
│   ├── dcmqrscp-primary.cfg.template   # Primary PACS config template
│   └── dcmqrscp-secondary.cfg.template # Secondary PACS config template
├── scripts/
│   ├── entrypoint.sh                   # Role-based startup dispatcher
│   ├── generate-test-data.sh           # Synthetic DICOM generation
│   └── wait-for-pacs.sh               # Readiness polling
├── data/
│   └── dicom-templates/                # dump2dcm reference templates
│       ├── ct-template.dump
│       ├── mr-template.dump
│       └── cr-template.dump
├── tests/
│   ├── test-echo.sh                    # C-ECHO tests
│   ├── test-store.sh                   # C-STORE tests
│   ├── test-find.sh                    # C-FIND tests
│   ├── test-move.sh                    # C-MOVE tests
│   └── test-all.sh                     # Full test suite runner
└── docs/
    ├── 01_research_dcmtk_dicom.md
    ├── 02_research_docker_approaches.md
    ├── 03_architecture_design.md
    └── 04_work_plan.md
```

## Troubleshooting

### "Association rejected" / "Connection refused"

1. **Check the service is running**: `docker compose ps` — all services should show "Up" or "healthy"
2. **Check the AE Title**: DICOM AE Titles are case-sensitive. Use exactly `DCMTK_PACS`, not `dcmtk_pacs`
3. **Check the port**: All containers listen on internal port `11112`. Host ports differ (11112, 11113, 11114)
4. **Check the network**: Services must be on the same Docker network (`dicom-net`)

```bash
# Verify service health
docker compose ps

# Check PACS logs
docker compose logs pacs-server

# Test TCP connectivity
docker compose exec test-client nc -zv pacs-server 11112
```

### C-MOVE fails / "No matching destination"

C-MOVE requires the destination AE to be registered in the PACS HostTable.

1. **Check the HostTable**: `docker compose exec pacs-server cat /tmp/dcmqrscp.cfg`
2. **Verify the destination is reachable**: `docker compose exec test-client echoscu storescp-receiver 11112`
3. **Destination AE must match**: The `-aem` value in `movescu` must match a HostTable entry

### "No such SOP Class" / Transfer syntax errors

DCMTK 3.6.7 supports standard uncompressed transfer syntaxes. If storing files with
exotic compression, convert first:

```bash
# Convert to Explicit VR Little Endian
docker compose exec test-client \
    dcmconv +te /dicom/testdata/compressed.dcm /dicom/testdata/uncompressed.dcm
```

### Tests fail with "0 studies found"

Test data may not have been loaded into the PACS:

```bash
# Check if test data exists
docker compose exec test-client ls -la /dicom/testdata/ct/

# Manually store test data
docker compose exec test-client \
    storescu -v -aet TEST_SCU -aec DCMTK_PACS \
    +sd +r pacs-server 11112 /dicom/testdata/

# Verify with C-FIND
docker compose exec test-client \
    findscu -v -S -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112 \
    -k QueryRetrieveLevel=STUDY -k PatientName="*" -k StudyInstanceUID
```

### Reset everything

```bash
# Full reset: stop containers, remove volumes, rebuild
docker compose down -v
docker compose up -d --build
```

### Debug logging

```bash
# Increase log verbosity
# In .env, set:
LOG_LEVEL=debug

# Restart the affected service
docker compose up -d pacs-server
docker compose logs -f pacs-server
```

## Development

### Rebuild after changes

```bash
# Rebuild image and restart all services
docker compose up -d --build

# Rebuild and restart a specific service
docker compose up -d --build pacs-server
```

### Custom entrypoint

Run any command using the `custom` role:

```bash
docker compose run --rm -e ROLE=custom test-client dcmdump /dicom/testdata/ct/ct_pat001_1.dcm
```

### Inspect DICOM files

```bash
# Dump file contents
docker compose exec test-client dcmdump /dicom/testdata/ct/ct_pat001_1.dcm

# Dump specific tags
docker compose exec test-client dcmdump +P PatientName +P StudyInstanceUID \
    /dicom/testdata/ct/ct_pat001_1.dcm
```

## Requirements

- Docker Engine 20.10+ with Docker Compose V2
- ~200 MB disk space for the image
- Ports 11112-11114 available on the host (configurable via `.env`)

## License

MIT
