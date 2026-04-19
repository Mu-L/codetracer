#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f /tmp/ct-browser-replay.pid ]; then
	PID=$(cat /tmp/ct-browser-replay.pid)
	if kill -0 "$PID" 2>/dev/null; then
		nginx -s stop -c "$SCRIPT_DIR/nginx.conf" -p "$REPO_ROOT" 2>/dev/null || kill "$PID" 2>/dev/null || true
	fi
	rm -f /tmp/ct-browser-replay.pid
fi
echo "nginx stopped."
