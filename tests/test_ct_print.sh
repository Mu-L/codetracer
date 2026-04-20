#!/bin/bash
set -e

# Test the ct print command against a mock JSONL span manifest.

MANIFEST=$(mktemp /tmp/ct_print_test_XXXX.jsonl)
trap 'rm -f "$MANIFEST"' EXIT

cat >"$MANIFEST" <<'EOF'
{"span_type":"web-request","metadata":{"http.method":"GET","http.url":"/api/users","http.status_code":"200","http.duration_ms":"12"},"status":"ok"}
{"span_type":"web-request","metadata":{"http.method":"POST","http.url":"/api/users","http.status_code":"201","http.duration_ms":"45"},"status":"ok"}
{"span_type":"web-request","metadata":{"http.method":"GET","http.url":"/error","http.status_code":"500","http.duration_ms":"8"},"status":"error"}
EOF

CT=${CT_BIN:-src/build-debug/bin/ct}
if [ ! -f "$CT" ]; then
	echo "SKIP: ct binary not found at $CT"
	exit 0
fi

echo "=== Test: ct print with span manifest ==="
$CT print "$MANIFEST"
echo ""

echo "=== Test: ct print with --filter errors ==="
$CT print "$MANIFEST" --filter errors
echo ""

echo "=== Test: ct print with --format json ==="
$CT print "$MANIFEST" --format json
echo ""

echo "=== Test: ct print with --limit 1 ==="
$CT print "$MANIFEST" --limit 1
echo ""

echo "=== Test: ct print with --function /error ==="
$CT print "$MANIFEST" --function /error
echo ""

echo "=== Test: ct print with --format csv ==="
$CT print "$MANIFEST" --format csv
echo ""

echo "PASS: all ct print tests completed"
