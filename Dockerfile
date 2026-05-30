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

# Create a dedicated non-root user to run the DICOM services. The DICOM port
# (11112) is >1024, so no privileged binding is required. Storage paths are
# owned by this user so the entrypoint's runtime mkdir/touch and Docker
# named-volume initialization (which inherits image ownership) work without root.
# NOTE: the Debian dcmtk package already creates a system "dcmtk" user/group,
# so we use a distinct "pacs" account to avoid a groupadd/useradd collision.
RUN groupadd -g 10001 pacs \
    && useradd -u 10001 -g pacs -d /dicom -s /usr/sbin/nologin pacs

# Create required directories
RUN mkdir -p /dicom/db /dicom/testdata /dicom/received /dicom/worklist /etc/dcmtk

# Copy configuration templates
COPY config/ /etc/dcmtk/

# Copy scripts and make executable
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Hand ownership of writable paths to the non-root user. Bind-mounted host
# paths (config:ro, tests:ro) are read-only; named volumes (pacs-data,
# received-data) inherit this ownership on first mount.
RUN chown -R pacs:pacs /dicom /etc/dcmtk

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

# Drop to the non-root user for all roles
USER pacs

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
