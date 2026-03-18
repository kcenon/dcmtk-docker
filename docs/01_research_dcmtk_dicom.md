# DCMTK & DICOM Protocol Research

> Comprehensive research document for building a Docker-based PACS test environment using DCMTK.

---

## Table of Contents

1. [DICOM Protocol Fundamentals](#1-dicom-protocol-fundamentals)
2. [DCMTK Command-Line Tools](#2-dcmtk-command-line-tools)
3. [DCMTK Configuration (dcmqrscp)](#3-dcmtk-configuration-dcmqrscp)
4. [Common PACS Test Scenarios](#4-common-pacs-test-scenarios)
5. [References](#5-references)

---

## 1. DICOM Protocol Fundamentals

### 1.1 DICOM Data Model Hierarchy

DICOM organizes medical imaging data in a four-level hierarchy:

```
Patient
  └── Study        (one patient has multiple studies)
        └── Series     (one study has multiple series)
              └── Instance   (one series has multiple images/objects)
```

| Level | Description | Key Attributes |
|-------|-------------|----------------|
| **Patient** | The subject of medical examination | PatientID, PatientName, PatientBirthDate, PatientSex |
| **Study** | A collection of one or more series acquired during a single visit | StudyInstanceUID, StudyDate, StudyTime, AccessionNumber, StudyDescription |
| **Series** | A group of related instances (same modality, body part) | SeriesInstanceUID, Modality, SeriesNumber, SeriesDescription |
| **Instance** (Image) | A single DICOM object (image, report, etc.) | SOPInstanceUID, SOPClassUID, InstanceNumber |

Each level is uniquely identified by a UID (Unique Identifier):
- `StudyInstanceUID` — unique per study
- `SeriesInstanceUID` — unique per series
- `SOPInstanceUID` — unique per instance (globally unique)

### 1.2 DICOM Service Classes (DIMSE-C)

DICOM network communication uses DIMSE (DICOM Message Service Element) commands. The core composite service commands are:

| Service | Direction | Purpose | Typical Use |
|---------|-----------|---------|-------------|
| **C-ECHO** | SCU → SCP | Verify connectivity ("DICOM ping") | Connectivity testing, health checks |
| **C-STORE** | SCU → SCP | Send/store a DICOM object | Image archival to PACS |
| **C-FIND** | SCU → SCP | Query for matching objects | Search studies by patient name, date, etc. |
| **C-MOVE** | SCU → SCP → dest | Request SCP to send objects to a third party | Image retrieval from PACS |
| **C-GET** | SCU → SCP | Request SCP to send objects back to requester | Direct image retrieval (no third party) |

**C-MOVE vs C-GET:**
- C-MOVE: The SCP opens a new association to the move destination. Requires the SCP to know the destination's network address (configured in its AE table).
- C-GET: The SCP sends objects back on the same association. Simpler but less commonly supported.

### 1.3 Association Negotiation

Before any DIMSE operation, two DICOM applications must establish an **association** through negotiation:

```
SCU (Client)                         SCP (Server)
    │                                     │
    │── A-ASSOCIATE-RQ ─────────────────> │  (propose: AE titles, abstract syntaxes, transfer syntaxes)
    │                                     │
    │<── A-ASSOCIATE-AC ──────────────── │  (accept/reject proposed contexts)
    │                                     │
    │── DIMSE commands (C-STORE, etc.) -> │  (actual data exchange)
    │                                     │
    │── A-RELEASE-RQ ───────────────────> │  (graceful disconnect)
    │<── A-RELEASE-RP ──────────────────  │
```

**Key negotiation parameters:**

| Parameter | Description |
|-----------|-------------|
| **Calling AE Title** | Identity of the requesting application (SCU) |
| **Called AE Title** | Identity of the receiving application (SCP) |
| **Presentation Context** | Pairing of an Abstract Syntax (SOP Class) with one or more Transfer Syntaxes |
| **Max PDU Size** | Maximum Protocol Data Unit size (typically 16384 bytes) |

**Presentation Context** is the most critical concept:
- The SCU proposes one or more presentation contexts (SOP Class + Transfer Syntaxes)
- The SCP accepts, rejects, or counter-proposes each context
- Only accepted contexts can be used during the association

> 99% of DICOM networking issues are related to association negotiation — mismatched AE titles, unsupported SOP classes, or incompatible transfer syntaxes.

### 1.4 Application Entity (AE) Title

An **AE Title** is a string identifier (up to 16 characters) that uniquely identifies a DICOM application on a network. Every DICOM node must have an AE Title configured.

**AE Title usage in PACS:**
- The PACS server has its own AE Title (e.g., `PACS_SCP`)
- Each client must be registered with its AE Title in the PACS configuration
- C-MOVE requires the destination's AE Title to be known by the SCP

### 1.5 Transfer Syntaxes

Transfer syntaxes define how DICOM data is encoded on the wire (byte order, VR encoding, compression).

**Core Uncompressed Transfer Syntaxes:**

| UID | Name | VR | Byte Order | Notes |
|-----|------|----|------------|-------|
| `1.2.840.10008.1.2` | Implicit VR Little Endian | Implicit | Little Endian | **Default/mandatory** — every DICOM implementation must support this |
| `1.2.840.10008.1.2.1` | Explicit VR Little Endian | Explicit | Little Endian | Most commonly used |
| `1.2.840.10008.1.2.1.99` | Deflated Explicit VR Little Endian | Explicit | Little Endian | Zlib compression |
| `1.2.840.10008.1.2.2` | Explicit VR Big Endian | Explicit | Big Endian | Retired — legacy only |

**Common Compressed Transfer Syntaxes:**

| UID | Name | Type |
|-----|------|------|
| `1.2.840.10008.1.2.4.50` | JPEG Baseline (8-bit) | Lossy |
| `1.2.840.10008.1.2.4.51` | JPEG Baseline (12-bit) | Lossy |
| `1.2.840.10008.1.2.4.57` | JPEG Lossless (Process 14) | Lossless |
| `1.2.840.10008.1.2.4.70` | JPEG Lossless, First-Order Prediction | Lossless |
| `1.2.840.10008.1.2.4.80` | JPEG-LS Lossless | Lossless |
| `1.2.840.10008.1.2.4.81` | JPEG-LS Near-Lossless | Lossy |
| `1.2.840.10008.1.2.4.90` | JPEG 2000 Lossless Only | Lossless |
| `1.2.840.10008.1.2.4.91` | JPEG 2000 | Lossy |
| `1.2.840.10008.1.2.5` | RLE Lossless | Lossless |
| `1.2.840.10008.1.2.4.100` | MPEG2 Main Profile | Video |
| `1.2.840.10008.1.2.4.102` | MPEG-4 AVC/H.264 High Profile | Video |

**VR (Value Representation):**
- **Implicit VR**: The VR is not included in the data stream; it must be looked up from the data dictionary by tag.
- **Explicit VR**: The VR is encoded directly in the data element, making parsing unambiguous.

### 1.6 SOP Classes

A **SOP Class** (Service-Object Pair Class) defines a specific DICOM service for a specific type of object. Each modality and data type has its own SOP Class UID.

**Common Storage SOP Classes:**

| SOP Class | UID | Modality |
|-----------|-----|----------|
| CT Image Storage | `1.2.840.10008.5.1.4.1.1.2` | CT |
| MR Image Storage | `1.2.840.10008.5.1.4.1.1.4` | MR |
| Computed Radiography Image Storage | `1.2.840.10008.5.1.4.1.1.1` | CR |
| Ultrasound Image Storage | `1.2.840.10008.5.1.4.1.1.6.1` | US |
| Digital X-Ray Image Storage (Presentation) | `1.2.840.10008.5.1.4.1.1.1.1` | DX |
| Secondary Capture Image Storage | `1.2.840.10008.5.1.4.1.1.7` | SC |
| RT Image Storage | `1.2.840.10008.5.1.4.1.1.481.1` | RTIMAGE |
| RT Dose Storage | `1.2.840.10008.5.1.4.1.1.481.2` | RTDOSE |
| RT Plan Storage | `1.2.840.10008.5.1.4.1.1.481.5` | RTPLAN |

**Query/Retrieve SOP Classes:**

| SOP Class | UID | Model |
|-----------|-----|-------|
| Patient Root Q/R FIND | `1.2.840.10008.5.1.4.1.2.1.1` | Patient Root |
| Patient Root Q/R MOVE | `1.2.840.10008.5.1.4.1.2.1.2` | Patient Root |
| Patient Root Q/R GET | `1.2.840.10008.5.1.4.1.2.1.3` | Patient Root |
| Study Root Q/R FIND | `1.2.840.10008.5.1.4.1.2.2.1` | Study Root |
| Study Root Q/R MOVE | `1.2.840.10008.5.1.4.1.2.2.2` | Study Root |
| Study Root Q/R GET | `1.2.840.10008.5.1.4.1.2.2.3` | Study Root |
| Verification SOP Class | `1.2.840.10008.1.1` | N/A (C-ECHO) |

### 1.7 Query/Retrieve Levels

Queries can be performed at different levels of the DICOM hierarchy:

| Level | Description | Common Query Keys |
|-------|-------------|-------------------|
| **PATIENT** | Find patients matching criteria | PatientID, PatientName, PatientBirthDate |
| **STUDY** | Find studies matching criteria | StudyDate, StudyDescription, AccessionNumber, Modality |
| **SERIES** | Find series within a study | SeriesInstanceUID, Modality, SeriesNumber |
| **IMAGE** | Find individual instances | SOPInstanceUID, InstanceNumber |

**Query/Retrieve Information Models:**
- **Patient Root**: Starts at Patient level, traverses down (Patient → Study → Series → Image)
- **Study Root**: Starts at Study level (Study → Series → Image) — most commonly used
- **Patient/Study Only**: Limited model without Series/Image levels (rarely used)

---

## 2. DCMTK Command-Line Tools

### 2.1 Network Tools

#### 2.1.1 echoscu — DICOM Verification (C-ECHO) SCU

**Purpose:** Tests basic DICOM connectivity ("DICOM ping").

```bash
echoscu [options] peer port
```

**Key Options:**

| Option | Description |
|--------|-------------|
| `-aet <title>` | Calling AE title (default: `ECHOSCU`) |
| `-aec <title>` | Called AE title (default: `ANY-SCP`) |
| `-to <seconds>` | Connection timeout |
| `-v` | Verbose output |
| `-d` | Debug output |

**Usage Examples:**

```bash
# Basic connectivity test
echoscu localhost 11112

# Test with specific AE titles
echoscu -v -aet MY_SCU -aec PACS_SCP pacs.hospital.com 104

# Test with timeout
echoscu -v -to 10 -aet MY_SCU -aec PACS_SCP localhost 11112
```

**Exit Codes:** 0 = success, 1 = syntax error, 60 = network failure, 70 = association aborted.

---

#### 2.1.2 storescu — DICOM Storage (C-STORE) SCU

**Purpose:** Sends DICOM files to a Storage SCP.

```bash
storescu [options] peer port dcmfile-in...
```

**Key Options:**

| Option | Description |
|--------|-------------|
| `-aet <title>` | Calling AE title (default: `STORESCU`) |
| `-aec <title>` | Called AE title (default: `ANY-SCP`) |
| `+sd` | Scan directories for input files |
| `+r` | Recurse into subdirectories |
| `-xi` | Propose only Implicit VR Little Endian |
| `-xs` | Propose JPEG Lossless + uncompressed |
| `--repeat <n>` | Repeat transmission n times |
| `-to <seconds>` | Connection timeout |

**Usage Examples:**

```bash
# Send a single DICOM file
storescu -v -aet MY_SCU -aec PACS_SCP localhost 11112 ct_image.dcm

# Send all DICOM files in a directory
storescu -v -aet MY_SCU -aec PACS_SCP localhost 11112 +sd +r /path/to/dicom/

# Send with JPEG Lossless transfer syntax
storescu -v --propose-lossless -aet MY_SCU -aec PACS_SCP localhost 11112 compressed.dcm

# Stress test: repeat 100 times
storescu -v --repeat 100 -aet MY_SCU -aec PACS_SCP localhost 11112 test.dcm
```

---

#### 2.1.3 storescp — DICOM Storage (C-STORE) SCP

**Purpose:** Receives DICOM files from Storage SCUs.

```bash
storescp [options] [port]
```

**Key Options:**

| Option | Description |
|--------|-------------|
| `-aet <title>` | AE title (default: `STORESCP`) |
| `-od <directory>` | Output directory for received files |
| `--fork` | Fork child process per association |
| `--sort-on-study-uid <prefix>` | Sort received files by Study UID |
| `--sort-on-patientname` | Sort by patient name |
| `-xcr <command>` | Execute command on each file received |
| `-xcs <command>` | Execute command when study is complete |
| `-pdu <bytes>` | Max PDU size (4096–131072) |

**Usage Examples:**

```bash
# Basic receiver on port 11112
storescp -v -od /dicom/incoming 11112

# Receive and sort by study UID
storescp -v -od /dicom/incoming --sort-on-study-uid study_ 11112

# Multi-process with post-receive script
storescp --fork -od /dicom/incoming \
  -xcr "/scripts/on_receive.sh #p #f #a #r" 11112

# Accept only Implicit VR Little Endian
storescp -v +xi -od /dicom/incoming 11112
```

---

#### 2.1.4 findscu — DICOM Query (C-FIND) SCU

**Purpose:** Queries a PACS for matching studies/series/images.

```bash
findscu [options] peer port [dcmfile-in...]
```

**Key Options:**

| Option | Description |
|--------|-------------|
| `-aet <title>` | Calling AE title (default: `FINDSCU`) |
| `-aec <title>` | Called AE title (default: `ANY-SCP`) |
| `-P` | Patient Root information model |
| `-S` | Study Root information model |
| `-W` | Modality Worklist information model |
| `-k <key=value>` | Specify query matching key |
| `-X` | Write responses to DICOM files |

**Usage Examples:**

```bash
# Query all studies for a patient
findscu -v -S -aet MY_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName="DOE^JOHN" \
  -k StudyDate \
  -k StudyDescription \
  -k StudyInstanceUID

# Query all CT studies from today
findscu -v -S -aet MY_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k ModalitiesInStudy=CT \
  -k StudyDate=20260319 \
  -k PatientName \
  -k StudyInstanceUID

# Query series within a study
findscu -v -S -aet MY_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=SERIES \
  -k StudyInstanceUID=1.2.3.4.5 \
  -k SeriesInstanceUID \
  -k Modality \
  -k SeriesNumber

# Export results to DICOM files
findscu -v -S -X -aet MY_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName="*"
```

**Query Key Syntax:**
- Dictionary name: `-k PatientName="SMITH*"`
- Tag format: `-k "(0010,0010)=SMITH*"`
- Empty key (return this attribute): `-k StudyDate`
- Wildcard: `*` (any), `?` (single char)

---

#### 2.1.5 movescu — DICOM Retrieve (C-MOVE) SCU

**Purpose:** Requests a PACS to send images to a specified destination.

```bash
movescu [options] peer port [dcmfile-in...]
```

**Key Options:**

| Option | Description |
|--------|-------------|
| `-aet <title>` | Calling AE title (default: `MOVESCU`) |
| `-aec <title>` | Called AE title (default: `ANY-SCP`) |
| `-aem <title>` | Move destination AE title (default: `MOVESCU`) |
| `+P <port>` | Port for incoming storage associations |
| `-P` | Patient Root information model |
| `-S` | Study Root information model |
| `-k <key=value>` | Specify query matching key |
| `-od <directory>` | Output directory for received files |

**Usage Examples:**

```bash
# Retrieve a specific study
movescu -v -S -aet MY_SCU -aec PACS_SCP -aem MY_SCU \
  +P 11113 -od /dicom/received \
  localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k StudyInstanceUID=1.2.3.4.5

# Retrieve all studies for a patient
movescu -v -P -aet MY_SCU -aec PACS_SCP -aem MY_SCU \
  +P 11113 -od /dicom/received \
  localhost 11112 \
  -k QueryRetrieveLevel=PATIENT \
  -k PatientID=12345
```

**Important:** For C-MOVE to work, the SCP must be configured with the network address of the move destination (`-aem`). The destination must also be listening for incoming storage associations on the specified port (`+P`).

---

#### 2.1.6 dcmqrscp — Full PACS Server (Q/R SCP)

**Purpose:** Complete DICOM archive with Storage, Query/Retrieve, and Verification services.

```bash
dcmqrscp [options] [port]
```

**Key Options:**

| Option | Description |
|--------|-------------|
| `-c <file>` | Configuration file path |
| `--single-process` | Single-process mode (for debugging) |
| `--fork` | Fork child process per association (default) |
| `+xs` / `-xs` | Accept/propose JPEG Lossless |
| `--allow-shutdown` | Allow remote shutdown |
| `--disable-get` | Disable C-GET support |
| `-v` | Verbose output |
| `-d` | Debug output |

**Supported Services:**

| Service | Role | Notes |
|---------|------|-------|
| C-ECHO | SCP | Verification (DICOM ping response) |
| C-STORE | SCP | Receive and archive DICOM objects |
| C-FIND | SCP | Query the archive database |
| C-MOVE | SCP + SCU | Retrieve — sends objects to destination |
| C-GET | SCP | Retrieve — sends objects back on same association |

**Usage Examples:**

```bash
# Start with configuration file
dcmqrscp -v -c /etc/dcmtk/dcmqrscp.cfg 11112

# Start with JPEG Lossless support
dcmqrscp -v -c dcmqrscp.cfg +xs -xs 11112

# Start in debug single-process mode
dcmqrscp -d --single-process -c dcmqrscp.cfg 11112
```

---

### 2.2 File Manipulation Tools

#### 2.2.1 dcmdump — DICOM File Inspector

**Purpose:** Displays DICOM file contents in human-readable format.

```bash
dcmdump [options] dcmfile-in
```

**Usage Examples:**

```bash
# Dump full file contents
dcmdump ct_image.dcm

# Dump specific tags only
dcmdump +P PatientName +P StudyInstanceUID ct_image.dcm

# Dump with value length
dcmdump +L ct_image.dcm
```

---

#### 2.2.2 dump2dcm — Create DICOM from Text Dump

**Purpose:** Converts ASCII text dump (from dcmdump) back into a DICOM file.

```bash
dump2dcm [options] dumpfile-in dcmfile-out
```

**Usage Examples:**

```bash
# Create DICOM from dump file
dump2dcm sample.dump output.dcm

# Create with explicit VR little endian
dump2dcm +te sample.dump output.dcm
```

**Dump File Format:**

```
(0008,0016) UI =CTImageStorage
(0008,0018) UI [1.2.3.4.5.6.7.8.9]
(0010,0010) PN [DOE^JOHN]
(0010,0020) LO [PATIENT001]
(0020,000D) UI [1.2.3.4.5.6.7.8]
(0020,000E) UI [1.2.3.4.5.6.7.8.1]
```

---

#### 2.2.3 dcmodify — Modify DICOM Attributes

**Purpose:** Modifies DICOM file attributes in place.

```bash
dcmodify [options] dcmfile-in...
```

**Usage Examples:**

```bash
# Modify patient name
dcmodify -m "PatientName=DOE^JOHN" image.dcm

# Insert a new attribute
dcmodify -i "(0010,0040)=M" image.dcm

# Erase an attribute
dcmodify -e PatientBirthDate image.dcm

# Generate new UIDs
dcmodify --gen-stud-uid --gen-ser-uid --gen-inst-uid image.dcm
```

---

#### 2.2.4 img2dcm — Convert Images to DICOM

**Purpose:** Converts standard image formats (JPEG, BMP) to DICOM files.

```bash
img2dcm [options] imgfile-in dcmfile-out
```

**Usage Examples:**

```bash
# Convert JPEG to Secondary Capture DICOM
img2dcm photo.jpg output.dcm

# Add patient/study metadata
img2dcm -k "PatientName=DOE^JOHN" -k "PatientID=12345" \
  -k "StudyDescription=Test Study" photo.jpg output.dcm
```

---

#### 2.2.5 dcmconv — Transfer Syntax Converter

**Purpose:** Converts DICOM files between transfer syntaxes.

```bash
dcmconv [options] dcmfile-in dcmfile-out
```

**Usage Examples:**

```bash
# Convert to Explicit VR Little Endian
dcmconv +te input.dcm output.dcm

# Convert to Implicit VR Little Endian
dcmconv +ti input.dcm output.dcm
```

---

### 2.3 Tool Summary Table

| Tool | Type | Role | Primary Function |
|------|------|------|------------------|
| **echoscu** | Network | SCU | DICOM connectivity test (C-ECHO) |
| **storescu** | Network | SCU | Send DICOM files (C-STORE) |
| **storescp** | Network | SCP | Receive DICOM files (C-STORE) |
| **findscu** | Network | SCU | Query PACS database (C-FIND) |
| **movescu** | Network | SCU | Request image retrieval (C-MOVE) |
| **getscu** | Network | SCU | Direct image retrieval (C-GET) |
| **dcmqrscp** | Network | SCP | Full PACS server (Store, Q/R, Verify) |
| **dcmrecv** | Network | SCP | Simple DICOM receiver |
| **dcmsend** | Network | SCU | Simple DICOM sender |
| **dcmdump** | File | — | Inspect DICOM file contents |
| **dump2dcm** | File | — | Create DICOM file from text dump |
| **dcmodify** | File | — | Modify DICOM attributes in-place |
| **dcmconv** | File | — | Convert between transfer syntaxes |
| **img2dcm** | File | — | Convert images (JPEG/BMP) to DICOM |
| **dcmqridx** | Utility | — | Rebuild dcmqrscp database index |

---

## 3. DCMTK Configuration (dcmqrscp)

### 3.1 Configuration File Structure

The `dcmqrscp.cfg` file is the central configuration for the PACS server. It has the following structure:

```
# Global Parameters
NetworkTCPPort  = 11112
MaxPDUSize      = 16384
MaxAssociations = 16

# Host Table
HostTable BEGIN
  ...
HostTable END

# Vendor Table
VendorTable BEGIN
  ...
VendorTable END

# AE Table
AETable BEGIN
  ...
AETable END
```

### 3.2 Global Parameters

| Parameter | Description | Default | Recommended |
|-----------|-------------|---------|-------------|
| `NetworkTCPPort` | TCP port for incoming associations | 104 | 11112 (non-root) |
| `MaxPDUSize` | Maximum Protocol Data Unit size in bytes | 16384 | 16384–131072 |
| `MaxAssociations` | Max concurrent associations | 16 | Depends on resources |

### 3.3 HostTable

Defines symbolic names for remote DICOM peers (their AE Title, hostname, and port).

**Format:**

```
HostTable BEGIN
  <symbolic_name> = (<AETitle>, <hostname>, <port>)
  <group_name>    = <symbolic_name1>, <symbolic_name2>, ...
HostTable END
```

**Example:**

```
HostTable BEGIN
  client1    = (CLIENT1, 172.20.0.10, 11113)
  client2    = (CLIENT2, 172.20.0.11, 11113)
  workstation = (WORKSTATION, 172.20.0.20, 4242)
  all_clients = client1, client2, workstation
HostTable END
```

### 3.4 VendorTable

Maps vendor names to host groups from the HostTable.

**Format:**

```
VendorTable BEGIN
  "<Vendor Name>" = <host_group_name>
VendorTable END
```

**Example:**

```
VendorTable BEGIN
  "Test Clients"  = all_clients
VendorTable END
```

### 3.5 AETable

Defines the Application Entities served by dcmqrscp, including storage locations and access control.

**Format:**

```
AETable BEGIN
  <AETitle>  <StoragePath>  <AccessMode>  (<MaxStudies>, <MaxBytesPerStudy>)  <Peers>
AETable END
```

**Fields:**

| Field | Description | Values |
|-------|-------------|--------|
| `AETitle` | AE title for this storage area | Up to 16 characters |
| `StoragePath` | Directory for stored DICOM files | Absolute path |
| `AccessMode` | Read/write permissions | `R` (read), `W` (write), `RW` (both) |
| `MaxStudies` | Maximum number of studies | Integer |
| `MaxBytesPerStudy` | Max storage per study | e.g., `1024mb` |
| `Peers` | Allowed remote peers | `ANY` or host group name |

**Example:**

```
AETable BEGIN
  PACS_SCP   /dicom/db/PACS     RW  (200, 1024mb)  ANY
  ARCHIVE    /dicom/db/ARCHIVE  RW  (500, 2048mb)  all_clients
  READONLY   /dicom/db/PUBLIC   R   (100, 512mb)   ANY
AETable END
```

### 3.6 Complete Configuration Example

```
# ============================================================
# dcmqrscp Configuration File
# ============================================================

# Network Settings
NetworkTCPPort  = 11112
MaxPDUSize      = 16384
MaxAssociations = 16

# ============================================================
# Host Table — Define known peers
# ============================================================
HostTable BEGIN
  client1     = (CLIENT1,     172.20.0.10,  11113)
  client2     = (CLIENT2,     172.20.0.11,  11113)
  workstation = (WORKSTATION, 172.20.0.20,  4242)
  all_peers   = client1, client2, workstation
HostTable END

# ============================================================
# Vendor Table — Group hosts by vendor
# ============================================================
VendorTable BEGIN
  "Test Clients" = all_peers
VendorTable END

# ============================================================
# AE Table — Define storage areas
# ============================================================
AETable BEGIN
  PACS_SCP  /dicom/db/PACS_SCP  RW  (200, 1024mb)  ANY
AETable END
```

### 3.7 Key Configuration Considerations

1. **Storage directories** must exist before starting dcmqrscp — they are not auto-created.
2. **index.dat** files are created automatically in each storage directory. They track the database of stored objects.
3. **AE Title matching** is case-sensitive in DCMTK.
4. **Peers = ANY** allows connections from any remote AE — suitable for testing but not for production.
5. For **C-MOVE**, the destination AE must be defined in the HostTable so dcmqrscp knows where to send images.

---

## 4. Common PACS Test Scenarios

### 4.1 Connectivity Test (C-ECHO)

**Purpose:** Verify DICOM network connectivity between two nodes.

```bash
# Basic connectivity test
echoscu -v -aet TEST_SCU -aec PACS_SCP localhost 11112

# Expected output (success):
# I: Requesting Association
# I: Association Accepted (Result: 0, 0)
# I: Sending Echo Request (MsgID 1)
# I: Received Echo Response (Success)
# I: Releasing Association

# With timeout for health checks
echoscu -v -to 5 -aet TEST_SCU -aec PACS_SCP localhost 11112
echo $?  # 0 = success, non-zero = failure
```

**Common Failures:**
- "Association rejected": Wrong AE Title, AE not registered, or port incorrect
- "Connection refused": Service not running or wrong port
- "Timeout": Network issue or firewall blocking

---

### 4.2 Image Archival (C-STORE)

**Purpose:** Store DICOM images in the PACS archive.

```bash
# Store a single image
storescu -v -aet TEST_SCU -aec PACS_SCP localhost 11112 ct_image.dcm

# Store multiple images from directory
storescu -v +sd +r -aet TEST_SCU -aec PACS_SCP localhost 11112 /dicom/images/

# Store with specific transfer syntax
storescu -v --propose-lossless -aet TEST_SCU -aec PACS_SCP localhost 11112 image.dcm
```

**Verification after store:**

```bash
# Query to verify the image was stored
findscu -v -S -aet TEST_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName \
  -k StudyInstanceUID \
  -k NumberOfStudyRelatedInstances
```

---

### 4.3 Study Query (C-FIND)

**Purpose:** Search the PACS database for studies matching criteria.

```bash
# Find all studies (wildcard)
findscu -v -S -aet TEST_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName="*" \
  -k PatientID \
  -k StudyDate \
  -k StudyDescription \
  -k ModalitiesInStudy \
  -k StudyInstanceUID \
  -k NumberOfStudyRelatedSeries \
  -k NumberOfStudyRelatedInstances

# Find studies by patient name (with wildcard)
findscu -v -S -aet TEST_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName="DOE*" \
  -k StudyDate \
  -k StudyInstanceUID

# Find studies by date range
findscu -v -S -aet TEST_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName \
  -k StudyDate="20260101-20260319" \
  -k StudyInstanceUID

# Find series within a specific study
findscu -v -S -aet TEST_SCU -aec PACS_SCP localhost 11112 \
  -k QueryRetrieveLevel=SERIES \
  -k StudyInstanceUID="1.2.3.4.5" \
  -k SeriesInstanceUID \
  -k Modality \
  -k SeriesNumber \
  -k SeriesDescription
```

---

### 4.4 Image Retrieval (C-MOVE)

**Purpose:** Retrieve images from the PACS to a specified destination.

```bash
# Retrieve a study (self as destination)
movescu -v -S \
  -aet TEST_SCU -aec PACS_SCP -aem TEST_SCU \
  +P 11113 -od /dicom/received \
  localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k StudyInstanceUID="1.2.3.4.5"

# Retrieve to a different destination
movescu -v -S \
  -aet TEST_SCU -aec PACS_SCP -aem WORKSTATION \
  localhost 11112 \
  -k QueryRetrieveLevel=STUDY \
  -k StudyInstanceUID="1.2.3.4.5"
```

**Prerequisites for C-MOVE:**
1. The move destination AE title must be registered in the dcmqrscp HostTable
2. The destination must be listening for incoming associations
3. The port in the HostTable must match the destination's listening port

---

### 4.5 End-to-End Workflow Test

A complete PACS test follows this sequence:

```bash
#!/bin/bash
PACS_HOST="localhost"
PACS_PORT="11112"
PACS_AET="PACS_SCP"
MY_AET="TEST_SCU"
MY_PORT="11113"

# Step 1: Connectivity
echo "=== Step 1: C-ECHO ==="
echoscu -v -aet $MY_AET -aec $PACS_AET $PACS_HOST $PACS_PORT

# Step 2: Store images
echo "=== Step 2: C-STORE ==="
storescu -v -aet $MY_AET -aec $PACS_AET $PACS_HOST $PACS_PORT /dicom/test_images/

# Step 3: Query stored images
echo "=== Step 3: C-FIND ==="
findscu -v -S -aet $MY_AET -aec $PACS_AET $PACS_HOST $PACS_PORT \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName="*" \
  -k StudyInstanceUID

# Step 4: Retrieve images
echo "=== Step 4: C-MOVE ==="
movescu -v -S -aet $MY_AET -aec $PACS_AET -aem $MY_AET \
  +P $MY_PORT -od /dicom/received \
  $PACS_HOST $PACS_PORT \
  -k QueryRetrieveLevel=STUDY \
  -k PatientName="*"
```

---

### 4.6 Stress Testing Patterns

```bash
# Pattern 1: Repeated single-file store
storescu -v --repeat 1000 -aet TEST_SCU -aec PACS_SCP localhost 11112 test.dcm

# Pattern 2: Parallel store sessions (using shell)
for i in $(seq 1 10); do
  storescu -aet "SCU_$i" -aec PACS_SCP localhost 11112 +sd +r /dicom/images/ &
done
wait

# Pattern 3: Concurrent query/store mix
storescu -aet STORE_SCU -aec PACS_SCP localhost 11112 +sd +r /dicom/images/ &
for i in $(seq 1 100); do
  findscu -S -aet FIND_SCU -aec PACS_SCP localhost 11112 \
    -k QueryRetrieveLevel=STUDY -k PatientName="*"
done
wait

# Pattern 4: Large dataset bulk load
storescu -v +sd +r -aet BULK_SCU -aec PACS_SCP localhost 11112 /dicom/large_dataset/
```

### 4.7 Sample DICOM File Creation (for Testing)

When you don't have real DICOM images, create synthetic test files:

```bash
# Method 1: Create from dump file
cat > /tmp/test.dump << 'EOF'
(0008,0016) UI =CTImageStorage
(0008,0018) UI [1.2.826.0.1.3680043.8.1055.1.20260319.1.1]
(0008,0020) DA [20260319]
(0008,0030) TM [120000]
(0008,0050) SH [ACC001]
(0008,0060) CS [CT]
(0008,0070) LO [Test Manufacturer]
(0008,1030) LO [Test Study]
(0010,0010) PN [DOE^JOHN]
(0010,0020) LO [PATIENT001]
(0010,0030) DA [19800101]
(0010,0040) CS [M]
(0020,000D) UI [1.2.826.0.1.3680043.8.1055.1.20260319.1]
(0020,000E) UI [1.2.826.0.1.3680043.8.1055.1.20260319.1.1]
(0020,0010) SH [STUDY001]
(0020,0011) IS [1]
(0020,0013) IS [1]
(0028,0002) US 1
(0028,0004) CS [MONOCHROME2]
(0028,0010) US 256
(0028,0011) US 256
(0028,0100) US 16
(0028,0101) US 12
(0028,0102) US 11
(0028,0103) US 0
(7FE0,0010) OW 0\0
EOF

dump2dcm /tmp/test.dump /tmp/test_ct.dcm

# Method 2: Convert a JPEG image to DICOM
img2dcm \
  -k "PatientName=DOE^JOHN" \
  -k "PatientID=PATIENT001" \
  -k "StudyDescription=Test Study" \
  photo.jpg output_sc.dcm

# Method 3: Modify existing DICOM file
dcmodify -m "PatientName=SMITH^JANE" -m "PatientID=PATIENT002" \
  --gen-stud-uid --gen-ser-uid --gen-inst-uid \
  existing.dcm
```

---

## 5. References

### Official Documentation
- [DCMTK Official Documentation](https://support.dcmtk.org/docs/) — Full API and tool reference
- [DCMTK dcmqrscp Manual](https://support.dcmtk.org/docs/dcmqrscp.html) — PACS server documentation
- [DCMTK storescu Manual](https://support.dcmtk.org/docs/storescu.html) — Storage SCU documentation
- [DCMTK storescp Manual](https://support.dcmtk.org/docs/storescp.html) — Storage SCP documentation
- [DCMTK findscu Manual](https://support.dcmtk.org/docs/findscu.html) — Query SCU documentation
- [DCMTK movescu Manual](https://support.dcmtk.org/docs/movescu.html) — Retrieve SCU documentation
- [DCMTK echoscu Manual](https://support.dcmtk.org/docs/echoscu.html) — Verification SCU documentation
- [DCMTK Networking Module](https://support.dcmtk.org/docs/mod_dcmnet.html) — All networking tools
- [DCMTK GitHub Repository](https://github.com/DCMTK/dcmtk) — Source code and sample configs

### DICOM Standard
- [DICOM Standard (NEMA)](https://dicom.nema.org) — Official DICOM specification
- [DICOM Standard Browser (Innolitics)](https://dicom.innolitics.com/) — Interactive DICOM tag browser
- [DICOM Library](https://www.dicomlibrary.com/) — SOP classes, transfer syntaxes lookup

### Guides and Tutorials
- [PACS Boot Camp — DICOM Operations](https://pacsbootcamp.com/dicom-operations/) — DICOM service class overview
- [DICOM is Easy (Blog)](https://dicomiseasy.blogspot.com/) — In-depth DICOM tutorials
- [Understanding DICOM with Orthanc](https://orthanc.uclouvain.be/book/dicom-guide.html) — Practical DICOM guide
- [DCMTK PACS Debugging Howto](https://support.dcmtk.org/redmine/projects/dcmtk/wiki/Howto_PACSDebuggingWithDCMTK) — DCMTK troubleshooting
- [DCMTK DeepWiki — Command Line Utilities](https://deepwiki.com/DCMTK/dcmtk/7-command-line-utilities) — Tool overview

### Docker References
- [DCMTK Docker Containers (pydicom)](https://pydicom.github.io/containers-dcmtk) — Pre-built DCMTK Docker images
- [khanlab/dcmtk_pacs](https://github.com/khanlab/dcmtk_pacs) — Example Docker-based DCMTK PACS

---

*Document generated: 2026-03-19 | For: dcmtk_docker project — Docker-based PACS test environment*
