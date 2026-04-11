#!/usr/bin/env bash

set -e

# Allow unfree packages so that codetracer-appimage (which carries an unfree
# license) can be evaluated during the check.
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure \
	--override-input codetracer-trace-format path:./libs/codetracer-trace-format
