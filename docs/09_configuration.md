# Configuration

Part of the dcmtk-docker documentation; start from the [README](../README.md).

## Environment Variables

The project uses `env.default` as the default configuration. To customize, copy
to `.env` and edit (`.env` takes precedence when both exist):

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
| `WLM_AE_TITLE` | `DCMTK_WLM` | Modality Worklist SCP AE Title |
| `WLM_HOST_PORT` | `11115` | Modality Worklist SCP host port |
| `WLM_STATION_AE` | `MODALITY01` | Scheduled Station AE Title `(0040,0001)` written into the generated worklist items |
| `TEST_SCU_AE_TITLE` | `TEST_SCU` | Test client AE Title |
| `PACS_BIND_ADDR` | `0.0.0.0` | Host interface the published ports bind to. Set to e.g. `127.0.0.1` to expose ports only to the local host (see Security Notes) |
| `DICOM_PORT` | `11112` | Internal container DICOM port |
| `MAX_PDU_SIZE` | `16384` | Maximum PDU size (bytes) |
| `MAX_ASSOCIATIONS` | `16` | Maximum concurrent associations |
| `MAX_STUDIES` | `200` | Maximum studies per storage area |
| `MAX_BYTES_PER_STUDY` | `1024mb` | Maximum bytes per study |
| `LOG_LEVEL` | `info` | Log level: debug, info, warn, error |
| `DICOM_MEM_LIMIT` | `512m` | Memory limit (`mem_limit`) for each service container |
| `DICOM_CPUS` | `1.0` | CPU limit (`cpus`) for each service container |
| `EXTRA_PEERS` | (empty) | Ad-hoc C-MOVE destinations for both PACS servers, space-separated `name=AE:host:port`; `./pacs.sh add-peer` appends to it in `.env` |
| `GENERATE_TEST_DATA` | `true` | Generate synthetic data on startup |
| `GENERATE_PIXEL_DATA` | `false` | Embed modality-realistic synthetic PixelData in generated files |
| `PIXEL_DATA_PROFILE` | `conservative` | `conservative` (CT 128, MR 128, CR 224) or `realistic` (CT 512, MR 256, CR 1024) |
| `CT_PIXEL_ROWS` / `CT_PIXEL_COLS` | (profile default) | Override CT dimensions independently of the profile |
| `MR_PIXEL_ROWS` / `MR_PIXEL_COLS` | (profile default) | Override MR dimensions independently of the profile |
| `CR_PIXEL_ROWS` / `CR_PIXEL_COLS` | (profile default) | Override CR dimensions independently of the profile |
| `OID_ROOT` | `1.2.826.0.1.3680043.8.499` | OID root for test UIDs |

## dcmqrscp Configuration

The PACS servers use `dcmqrscp.cfg` templates in `config/`. Templates use `${VARIABLE}`
placeholders processed by `envsubst` at container startup.

- `config/dcmqrscp-primary.cfg.template` — Primary PACS config
- `config/dcmqrscp-secondary.cfg.template` — Secondary PACS config

Key sections:
- **HostTable**: Defines known peers for C-MOVE destination routing
- **AETable**: Defines storage areas, access mode, and capacity limits
- **Global**: Network port, PDU size, max associations
