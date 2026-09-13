# Test Suite

Part of the dcmtk-docker documentation; start from the [README](../README.md).

## Run All Tests

```bash
./pacs.sh test
```

## Run Individual Tests

```bash
./pacs.sh test echo     # Connectivity
./pacs.sh test store    # Image archival
./pacs.sh test find     # Query
./pacs.sh test move     # Retrieval
./pacs.sh test pixeldata  # PixelData smoke (opt-in, see below)
./pacs.sh test transfer-syntax  # Uncompressed transfer-syntax matrix
./pacs.sh test load-smoke # Operational load smoke (parallel C-STORE + C-FIND)
```

### Transfer syntax compatibility

The synthetic data generator emits every instance as Explicit VR Little
Endian. The `transfer-syntax` suite (`tests/test-transfer-syntax.sh`) takes
that source instance and uses `dcmconv` to convert it to the three
uncompressed syntaxes that `dcmqrscp` accepts with its default options,
then verifies `storescu` can negotiate each one against the primary PACS:

| Label            | Transfer Syntax UID    | `dcmconv` flag |
|------------------|------------------------|----------------|
| explicit-vr-le   | 1.2.840.10008.1.2.1    | `+te`          |
| implicit-vr-le   | 1.2.840.10008.1.2      | `+ti`          |
| explicit-vr-be   | 1.2.840.10008.1.2.2    | `+tb`          |

The suite covers no compressed syntax (JPEG / JPEG-LS / RLE / JPEG2000),
because the primary PACS accepts none: the entrypoint starts `dcmqrscp`
with its default preference (`+x=`), which offers only the three syntaxes
above. The image already has DCMTK's JPEG, JPEG-LS, and RLE codec tools
(`dcmcjpeg`, `dcmcjpls`, `dcmcrle`, and the matching `dcmdjpeg`,
`dcmdjpls`, and `dcmdrle` decoders); it has no JPEG 2000 codec. To extend
coverage:

1. Pass `dcmqrscp` a preference option for the target syntax (the
   entrypoint passes none today), such as `+xs` (JPEG Lossless), `+xt`
   (JPEG-LS Lossless), or `+xr` (RLE Lossless). Each option adds one
   compressed syntax to the three above; an association negotiation
   profile (`-xf`) can list several.
2. Create the test object with `dcmcjpeg`, `dcmcjpls`, or `dcmcrle`.
   `dcmconv` writes only uncompressed and deflated syntaxes.
3. Add the target UID and the matching `storescu` proposal option (`-xs`,
   `-xt`, or `-xr`) to the matrix in `tests/test-transfer-syntax.sh`.

## Load Smoke Testing

The `load-smoke` suite drives the PACS with parallel `storescu` workers
and a concurrent `findscu` probe, exercising the `MAX_ASSOCIATIONS`
ceiling, association cleanup, and mixed store/query behaviour that the
functional suites do not cover.

```bash
# Defaults are conservative so the suite stays inside ~1-2 min of CI budget
./pacs.sh test load-smoke

# Probe a heavier mix (e.g. saturate the default MAX_ASSOCIATIONS=16 ceiling)
LOAD_SMOKE_PARALLEL=4 LOAD_SMOKE_REPEAT=3 ./pacs.sh test load-smoke
```

| Env var | Default | Purpose |
|---------|---------|---------|
| `LOAD_SMOKE_PARALLEL` | `2` | Number of parallel `storescu` workers |
| `LOAD_SMOKE_REPEAT` | `2` | Iterations of `storescu` per worker |
| `LOAD_SMOKE_TIMEOUT` | `60` | Per-association timeout in seconds |
| `LOAD_SMOKE_FIND_REPS` | `5` | Concurrent `findscu` iterations (0 disables the probe) |

The suite passes when at least half of the parallel workers complete and
the post-load study count is at or above the pre-load baseline. Failed
worker logs are emitted to stderr so the offending association can be
attributed back to its worker.

## Test Data

Synthetic DICOM files are generated automatically at first startup:

| Patient | PatientID | Modality | Series | Instances | Study Description |
|---------|-----------|----------|--------|-----------|-------------------|
| DOE^JOHN | PAT001 | CT | 1 | 5 | CT Abdomen |
| SMITH^JANE | PAT002 | MR | 2 (T1, T2) | 6 | MR Brain |
| WANG^LEI | PAT003 | CR | 1 | 2 | Chest PA |

The patients, counts, and descriptions come from `scripts/fixture-manifest.sh`
(see [Test-data manifest](#test-data-manifest-single-source-of-truth)).

To add custom DICOM files, place them in the `data/` directory.
They will be available in the test-client at `/dicom/testdata/`.

### Source fixtures vs generated artifacts

The `data/` directory mixes two kinds of content. Only the source fixtures are
tracked in git; generated artifacts are ignored via `.gitignore` and can be
wiped safely.

| Path | Kind | Tracked | Notes |
|------|------|---------|-------|
| `data/dicom-templates/` | Source fixture | Yes | `*.dump` templates consumed by the generator; never delete |
| `data/ct/`, `data/mr/`, `data/cr/` | Generated | No | Synthetic DICOM written on first `./pacs.sh up` |
| `data/dicom-output/`, `data/received/` | Generated | No | Test runtime artifacts |

### Test-data manifest (single source of truth)

The identity of the synthetic dataset — the OID root, every study/series UID,
the expected instance counts, and the patient demographics — lives in one file:
`scripts/fixture-manifest.sh`. Both the generator (`scripts/generate-test-data.sh`)
and the test scripts (via `tests/test-helpers.sh`) source it, so no magic UID or
count is duplicated where it could drift out of sync.

**Pointing the suite at an external (non-DCMTK) PACS.** Every query key and
assertion reads from the manifest, so you can validate a third-party archive
without editing a test:

1. Set `OID_ROOT` to a value that will not collide with the target's data
   (e.g. `OID_ROOT=1.2.3.myorg.test`).
2. Generate the dataset (`scripts/generate-test-data.sh`) and load it into the
   target PACS with `storescu`.
3. Point the test scripts at the target via the `PACS_HOST` / `PACS_PORT` /
   `PACS_AE_TITLE` environment variables and run them — the assertions follow
   `OID_ROOT` automatically.

To regenerate test data, remove the generated directories and restart:

```bash
./pacs.sh clean-data            # remove only generated artifacts
docker compose restart test-client
```

`./pacs.sh clean-data --dry-run` prints the paths it would remove without
touching the filesystem. Source fixtures in `data/dicom-templates/` are
always preserved.

### Synthetic PixelData (optional)

By default, generated files carry only metadata (Patient/Study/Series/Image/SOP modules)
— enough to exercise the DICOM **network layer** (C-STORE, C-FIND, C-MOVE) but not
the **image pipeline** (decode, window/level, render). To make the synthetic files
usable by viewers and rendering pipelines, set `GENERATE_PIXEL_DATA=true`:

```bash
# Wipe existing test data and re-generate with PixelData embedded
rm -rf data/ct data/mr data/cr
GENERATE_PIXEL_DATA=true docker compose up -d --force-recreate pacs-server
```

When enabled, every CT/MR/CR instance gains a **modality-realistic** Image Pixel
Module (`Rows`, `Columns`, `BitsAllocated`, `BitsStored`, `HighBit`,
`PixelRepresentation`, `SamplesPerPixel`, `PhotometricInterpretation`), a
modality-appropriate display window, and a deterministic synthetic
`(7FE0,0010) OW` buffer:

| Modality | Rows × Cols (conservative) | Rows × Cols (realistic) | BitsStored | PixelRep | Pattern | Extras |
|----------|---------------------------|--------------------------|------------|----------|---------|--------|
| CT       | 128 × 128                 | 512 × 512                | 16         | 1 (signed)   | 7-band signed Hounsfield ramp (-1000..1000)        | RescaleIntercept/Slope/Type, W/L 400/40 |
| MR       | 128 × 128                 | 256 × 256                | 12         | 0 (unsigned) | 4-band intensity ramp (CSF .. fat)                  | W/L 4096/2048                            |
| CR       | 224 × 224                 | 1024 × 1024              | 14         | 0 (unsigned) | Chest silhouette (thorax + lung fields + spine)     | W/L 16383/8192, PresentationLUTShape=IDENTITY |

Switch profile or override individual modalities via env vars:

```bash
# Switch all three modalities to realistic dimensions
PIXEL_DATA_PROFILE=realistic GENERATE_PIXEL_DATA=true \
    docker compose up -d --force-recreate pacs-server

# Override one modality (e.g. CR) without touching the others
GENERATE_PIXEL_DATA=true CR_PIXEL_ROWS=512 CR_PIXEL_COLS=512 \
    docker compose up -d --force-recreate pacs-server
```

Verify with `dcmdump`:

```bash
docker compose exec test-client dcmdump /dicom/testdata/ct/ct_pat001_1.dcm | grep -E 'PixelData|Rows|Columns'
```

A smoke test that runs `dcm2pnm` against a generated file is included as
`tests/test-pixeldata.sh` (auto-skipped when `GENERATE_PIXEL_DATA` is unset).
Run it explicitly through the `pacs.sh` CLI once test data has been generated
with PixelData embedded:

```bash
# Wipe stale data, regenerate with conservative profile (default), run smoke test
rm -rf data/ct data/mr data/cr
GENERATE_PIXEL_DATA=true docker compose up -d --force-recreate pacs-server test-client
GENERATE_PIXEL_DATA=true ./pacs.sh test pixeldata

# Same with the realistic profile (larger frames, higher memory/CPU)
rm -rf data/ct data/mr data/cr
PIXEL_DATA_PROFILE=realistic GENERATE_PIXEL_DATA=true \
    docker compose up -d --force-recreate pacs-server test-client
GENERATE_PIXEL_DATA=true PIXEL_DATA_PROFILE=realistic \
    ./pacs.sh test pixeldata
```

When `GENERATE_PIXEL_DATA` is left unset, `./pacs.sh test pixeldata` runs the
script which prints a `SKIP` line and exits 0 — useful for confirming the CLI
wiring without regenerating any data. CI currently exercises the conservative
profile only; the realistic profile remains an opt-in local check.

Re-generating PixelData requires wiping the per-modality `data/ct`, `data/mr`,
and `data/cr` directories so the test-client recreates them on next start. The
PACS storage volume also caches a `<storage>/<AE_TITLE>/.indexed` marker (see
note below) — delete it whenever the underlying instances change so the server
re-indexes them.

> **Note:** The `pacs-server` indexes test DICOM files into its database on
> first startup and writes a marker file at `<storage>/<AE_TITLE>/.indexed`
> to skip re-indexing on subsequent restarts. After adding new DICOM files
> to the storage area, delete the marker (or wipe the storage volume) to
> force a re-index. See [docs/06_dcmqridx_behavior.md](06_dcmqridx_behavior.md)
> for details on the underlying `dcmqridx` semantics.
