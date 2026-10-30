# DCMTK PACS Test Environment
# Single image, multiple roles via ROLE environment variable
# Based on debian:trixie-slim with DCMTK 3.6.9 (apt).
# Pin the base manifest; accept Debian security revisions of DCMTK 3.6.9.
# An exact revision can be supplied with --build-arg DCMTK_PACKAGE_VERSION=...
# while that revision remains in the apt repositories. See docs/09_configuration.md.
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS base
ARG DCMTK_PACKAGE_VERSION=3.6.9-*

LABEL maintainer="dcmtk-pacs-docker"
LABEL description="DCMTK-based PACS test environment with all DICOM tools"

# Install DCMTK and required utilities
# - dcmtk: all command-line DICOM tools (storescu, storescp, dcmqrscp, etc.)
# - gettext-base: provides envsubst for config template processing
# - netcat-openbsd: for TCP health checks (nc)
RUN apt-get update && apt-get install -y --no-install-recommends \
    "dcmtk=${DCMTK_PACKAGE_VERSION}" \
    gettext-base \
    netcat-openbsd \
    openssl \
    && dpkg-query -W dcmtk > /usr/share/doc/dcmtk/package-version.txt \
    && rm -rf /var/lib/apt/lists/*

# Rebuild only the PACS executable from the matching authenticated Debian
# source package. The other SCU/codec tools remain the distribution binaries.
# An atomic filename reservation patch fixes concurrent C-STORE (#115).
FROM base AS pacs-source
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
       build-essential cmake patch libssl-dev zlib1g-dev libwrap0-dev \
       "libdcmtk-dev=$(dpkg-query -W -f='${Version}' dcmtk)" \
    && mkdir /src && cd /src \
    && apt-get source "dcmtk=$(dpkg-query -W -f='${Version}' dcmtk)"
FROM pacs-source AS pacs-build
COPY patches/ /patches/
RUN bash /patches/build-pacs.sh

FROM base
COPY --from=pacs-build /build/bin/dcmqrscp /usr/local/bin/dcmqrscp
COPY --from=pacs-build /src/dcmtk-*/COPYRIGHT /usr/share/doc/dcmtk/COPYRIGHT.patched-pacs
COPY patches/atomic-store-filenames.patch /usr/share/doc/dcmtk/

# Create a dedicated non-root user to run the DICOM services. The DICOM port
# (11112) is >1024, so no privileged binding is required. Storage paths are
# owned by this user so the entrypoint's runtime mkdir/touch and Docker
# named-volume initialization (which inherits image ownership) work without root.
# NOTE: the Debian dcmtk package already creates a system "dcmtk" user/group,
# so we use a distinct "pacs" account to avoid a groupadd/useradd collision.
RUN groupadd -g 10001 pacs \
    && useradd -u 10001 -g pacs -d /dicom -s /usr/sbin/nologin pacs

# Create required directories
RUN mkdir -p /dicom/db /dicom/testdata /dicom/received /dicom/worklist /dicom/certs /etc/dcmtk

# Copy configuration templates
COPY config/ /etc/dcmtk/

# Copy scripts and make executable
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Hand ownership of writable paths to the non-root user. Bind-mounted host
# paths (config:ro, tests:ro) are read-only; named volumes (pacs-data,
# received-data) inherit this ownership on first mount.
RUN chown -R pacs:pacs /dicom /etc/dcmtk

# Default DICOM port metadata; Compose publishes the configured DICOM_PORT.
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
