#!/usr/bin/env bash
# Generate self-signed TLS certificates for local development.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/certs"

mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
	echo "Certificates already exist in $CERT_DIR"
	exit 0
fi

echo "Generating self-signed TLS certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "$CERT_DIR/server.key" \
	-out "$CERT_DIR/server.crt" \
	-days 365 \
	-subj "/CN=localhost" \
	-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo "Certificate generated:"
echo "  $CERT_DIR/server.crt"
echo "  $CERT_DIR/server.key"
