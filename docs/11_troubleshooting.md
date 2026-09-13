# Troubleshooting

Part of the dcmtk-docker documentation; start from the [README](../README.md).

## "Association rejected" / "Connection refused"

1. **Check the service is running**: `./pacs.sh status` — all services should show "healthy"
2. **Check the AE Title**: DICOM AE Titles are case-sensitive. Use exactly `DCMTK_PACS`, not `dcmtk_pacs`.
   The PACS healthcheck issues `echoscu -aec ${AE_TITLE}` against itself, so a container will be marked
   `unhealthy` if the configured `AE_TITLE` does not match what `dcmqrscp` actually loaded.
3. **Check the port**: All containers listen on internal port `11112`. Host ports differ (11112, 11113, 11114, 11115)
4. **Check the network**: Services must be on the same Docker network (`dicom-net`)

```bash
# Verify service health
./pacs.sh status

# Check PACS logs
./pacs.sh logs pacs-server

# Test DICOM connectivity
docker compose exec test-client echoscu -aet TEST_SCU -aec DCMTK_PACS pacs-server 11112
```

## C-MOVE fails / "No matching destination"

C-MOVE requires the destination AE to be registered in the PACS HostTable.

1. **Check the HostTable**: `docker compose exec pacs-server cat /tmp/dcmqrscp.cfg`
2. **Verify the destination is reachable**: `docker compose exec test-client echoscu -aet TEST_SCU -aec STORE_SCP storescp-receiver 11112`
3. **Destination AE must match**: The `-aem` value in `movescu` must match a HostTable entry

## "No such SOP Class" / Transfer syntax errors

DCMTK 3.6.7 supports standard uncompressed transfer syntaxes. If storing files with
exotic compression, convert first:

```bash
# Convert to Explicit VR Little Endian
docker compose exec test-client \
    dcmconv +te /dicom/testdata/compressed.dcm /dicom/testdata/uncompressed.dcm
```

## Tests fail with "0 studies found"

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

## Reset everything

```bash
# Full reset: stop containers, remove volumes, rebuild
./pacs.sh reset

# Or manually:
docker compose down -v
docker compose up -d --build
```

## Debug logging

```bash
# Increase log verbosity
# In .env, set:
LOG_LEVEL=debug

# Restart the affected service
docker compose up -d pacs-server
docker compose logs -f pacs-server
```
