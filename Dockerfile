# DCMTK PACS Test Environment
# Single image, multiple roles via ROLE environment variable
# Based on debian:bookworm-slim with DCMTK 3.6.7 (apt)

FROM debian:bookworm-slim

LABEL maintainer="dcmtk-pacs-docker"
LABEL description="DCMTK-based PACS test environment with all DICOM tools"

# Install DCMTK and required utilities
# - dcmtk: all command-line DICOM tools (storescu, storescp, dcmqrscp, etc.)
# - gettext-base: provides envsubst for config template processing
# - netcat-openbsd: for TCP health checks (nc)
RUN apt-get update && apt-get install -y --no-install-recommends \
    dcmtk \
    gettext-base \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Create required directories
RUN mkdir -p /dicom/db /dicom/testdata /dicom/received /etc/dcmtk

# Copy configuration templates
COPY config/ /etc/dcmtk/

# Copy scripts and make executable
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Default DICOM port
EXPOSE 11112

# Default environment variables
ENV ROLE=pacs-server \
    AE_TITLE=DCMTK_PACS \
    DICOM_PORT=11112 \
    STORAGE_DIR=/dicom/db \
    LOG_LEVEL=info \
    MAX_PDU_SIZE=16384 \
    MAX_ASSOCIATIONS=16 \
    MAX_STUDIES=200 \
    MAX_BYTES_PER_STUDY=1024mb \
    GENERATE_TEST_DATA=true \
    TEST_DATA_DIR=/dicom/testdata \
    OID_ROOT=1.2.826.0.1.3680043.8.499

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
