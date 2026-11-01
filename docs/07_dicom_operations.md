# DICOM Operations

Part of the dcmtk-docker documentation; start from the [README](../README.md).

## Start and Stop

```bash
# Start all services (recommended)
./pacs.sh up

# Or use docker compose directly
docker compose up -d

# Start specific services only
docker compose up -d pacs-server test-client

# View logs
./pacs.sh logs pacs-server

# Stop all services (keep data)
./pacs.sh down

# Stop and remove all data
docker compose down -v
```

## C-ECHO (Connectivity Test)

```bash
# Quick check via pacs.sh (auto-detects host/container)
./pacs.sh echo localhost 11112

# Check secondary PACS by overriding the Called AE Title
./pacs.sh echo localhost 11113 DCMTK_PAC2

# From test-client container
docker compose exec test-client \
    echoscu -v -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112

# From host (requires DCMTK installed locally)
echoscu -v -aet MY_SCU -aec DCMTK_PACS localhost 11112
```

## C-STORE (Send Images)

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

## C-FIND (Query)

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

## C-MOVE (Retrieve)

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

## Interactive Shell

```bash
# Open a shell via pacs.sh
./pacs.sh shell

# Or use docker compose directly
docker compose exec test-client bash

# All DCMTK tools are available:
# echoscu, storescu, findscu, movescu, getscu,
# dcmdump, dump2dcm, dcmodify, dcmconv, img2dcm, dcmqridx
```

## Connect External DICOM Application

Any DICOM-capable application can connect to the PACS via the host-mapped ports:

| Parameter | Value |
|-----------|-------|
| Host | `<docker-host-ip>` or `localhost` |
| Port | `11112` (primary), `11113` (secondary) |
| Called AE Title | `DCMTK_PACS` or `DCMTK_PAC2` |
| Calling AE Title | Any (Peers = ANY in test config — see [Security Notes](10_security.md)) |

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
