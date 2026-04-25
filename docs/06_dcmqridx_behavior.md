# dcmqridx Idempotency Behavior

> Investigation of `dcmqridx` index registration semantics on repeated invocations
> with the same SOP Instance UIDs (relevant to container restart scenarios).
>
> Related issue: `kcenon/dcmtk-docker#5`

## Summary

When `dcmqridx` is run multiple times on the same DICOM dataset (same SOP
Instance UIDs), the resulting `index.dat` file does **not** grow unboundedly,
and duplicate logical entries are **not** created. DCMTK detects existing SOP
Instance UIDs and reuses the corresponding record slots in `index.dat`.

This means re-running `dcmqridx` across container restarts is functionally safe
with respect to index integrity. However, it still performs unnecessary I/O
work proportional to the test dataset size on every container start.

## Source-level Evidence

The relevant code path in DCMTK (verified against the upstream `master` branch
of `DCMTK/dcmtk`):

1. `dcmqridx.cc` invokes `DcmQueryRetrieveIndexDatabaseHandle::storeRequest()`
   for each input DICOM file.

   Source: `dcmqrdb/apps/dcmqridx.cc` — call site:
   `hdl.storeRequest(sclass, sinst, opt_imageFile, &status, opt_isNewFlag);`

2. `storeRequest()` (in `dcmqrdb/libsrc/dcmqrdbi.cc`) calls
   `removeDuplicateImage(SOPInstanceUID, StudyInstanceUID, pStudyDesc, newImageFileName)`
   before adding the new record. This function searches existing index records
   for a matching SOP Instance UID and, if found:
   - removes the previous idx record (via `DB_IdxRemove`),
   - conditionally deletes the previous image file only if its path differs
     from the file being re-registered, and
   - updates study metadata (image count, study size).

3. `DB_IdxRemove(idx)` does **not** truncate `index.dat`. It overwrites the
   record at its current offset with a blank record (`filename[0] = '\0'`).
   The DCMTK comment in source explicitly states:

   > "Just put a record with filename == ''"

   Subsequent calls to `DB_IdxAdd` reuse these tombstoned slots:

   > "A place is free if filename is empty"

### Implications

| Aspect | Behavior on re-indexing same SOP Instance UIDs |
|--------|------------------------------------------------|
| Logical duplicates in index | None — the previous record is removed first. |
| `index.dat` file size | Does not grow per re-run; tombstone slots are reused. |
| Image files on disk | Preserved when re-registered with the same path. |
| CPU / I/O cost | Linear in dataset size; runs every time on each invocation. |
| Behavior across DCMTK versions | Verified against current upstream; may change in the future. |

## Reference Sources

- DCMTK upstream repository (verified against `master` at investigation time):
  `https://github.com/DCMTK/dcmtk`
- `dcmqrdb/apps/dcmqridx.cc` — entry point for the `dcmqridx` tool
- `dcmqrdb/libsrc/dcmqrdbi.cc` — `storeRequest`, `removeDuplicateImage`,
  `DB_IdxRemove`, `DB_IdxAdd`
- DCMTK Q/R database documentation:
  `https://support.dcmtk.org/docs/classDcmQueryRetrieveIndexDatabaseHandle.html`

## Operational Decision

Despite `dcmqridx` being effectively idempotent with respect to `index.dat`
growth and logical entry uniqueness, the entrypoint script applies a
conservative marker-file guard at `${STORAGE_DIR}/${AE_TITLE}/.indexed`:

- After the first successful indexing run, the marker file is created.
- On subsequent container starts, if the marker exists, the indexing block
  is skipped entirely.
- To force re-indexing (for example, after adding new test DICOM files or
  changing AE title), delete the marker file or remove the storage volume.

### Rationale for the marker

1. **Avoids redundant I/O** on every container restart, which becomes
   noticeable as the synthetic dataset grows.
2. **Defense in depth** — if the upstream DCMTK behavior changes in a future
   release such that re-indexing produces growth or duplicates, this guard
   prevents regression without requiring code changes here.
3. **Explicit, observable state** — the presence or absence of the marker
   makes the indexing decision visible during troubleshooting.

The trade-off is that newly added test DICOM files are not picked up
automatically across restarts; the user must either delete the marker file
or wipe the storage volume. This is documented in `README.md` and in the
inline comment block in `scripts/entrypoint.sh`.
