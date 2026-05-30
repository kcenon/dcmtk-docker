#!/bin/bash
set -euo pipefail

# Generate a self-signed CA plus server and client certificates/keys for the
# TLS profile. Usage: gen-certs.sh [output_dir]
#
# DCMTK's TLS (+tls) validates the certificate chain against the trusted CA
# (+cf) but does not strictly verify the hostname, so a single CA-signed server
# cert works for every PACS node and for host-side testing.
#
# Self-signed test certificates only - NOT for production use.

CERT_DIR="${1:-${TLS_CERT_DIR:-/dicom/certs}}"
DAYS="${TLS_CERT_DAYS:-3650}"

mkdir -p "${CERT_DIR}"
C="${CERT_DIR}"

# Idempotent: skip if a full set already exists (e.g. on container restart or
# when a peer already generated them into the shared volume).
if [ -f "${C}/server-cert.pem" ] && [ -f "${C}/client-cert.pem" ] && [ -f "${C}/ca-cert.pem" ]; then
    echo "[gen-certs] certificates already present in ${C}, skipping."
    exit 0
fi

echo "[gen-certs] generating self-signed TLS test certificates in ${C}"

# Certificate authority
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${C}/ca-key.pem" -out "${C}/ca-cert.pem" \
    -days "${DAYS}" -subj "/CN=dcmtk-docker-test-ca" 2>/dev/null

# Server certificate signed by the CA
openssl req -newkey rsa:2048 -nodes \
    -keyout "${C}/server-key.pem" -out "${C}/server-req.pem" \
    -subj "/CN=dcmtk-docker-pacs" 2>/dev/null
openssl x509 -req -in "${C}/server-req.pem" \
    -CA "${C}/ca-cert.pem" -CAkey "${C}/ca-key.pem" -CAcreateserial \
    -out "${C}/server-cert.pem" -days "${DAYS}" 2>/dev/null

# Client certificate signed by the CA
openssl req -newkey rsa:2048 -nodes \
    -keyout "${C}/client-key.pem" -out "${C}/client-req.pem" \
    -subj "/CN=dcmtk-docker-client" 2>/dev/null
openssl x509 -req -in "${C}/client-req.pem" \
    -CA "${C}/ca-cert.pem" -CAkey "${C}/ca-key.pem" -CAcreateserial \
    -out "${C}/client-cert.pem" -days "${DAYS}" 2>/dev/null

# Drop the CSRs; keep CA, server, and client material.
rm -f "${C}/server-req.pem" "${C}/client-req.pem"

# Make the keys readable by the non-root runtime user that owns /dicom.
chmod 0640 "${C}"/*.pem 2>/dev/null || true

echo "[gen-certs] done: ca-cert.pem, server-{cert,key}.pem, client-{cert,key}.pem"
