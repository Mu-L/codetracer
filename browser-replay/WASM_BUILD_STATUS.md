# WASM Build Status

## Current State

The replay-server WASM build (`wasm-pack build --features browser-transport`)
currently fails due to C cross-compilation issues in tree-sitter language
grammars. The wasm-sysroot shims are missing `strcmp` and `isdigit` functions.

## What Works

- Rust code compiles for `browser-transport` feature (no Rust errors)
- Nim emulator C API compiles natively and passes tests
- Nim → C file generation works (`build_wasm_api.sh`)
- Browser transport infrastructure (nginx, worker.js, postMessage) is ready
- Mock worker transport test validates the DAP-over-postMessage contract

## What Needs Fixing

1. **wasm-sysroot/include/string.h**: Add `strcmp` stub
2. **wasm-sysroot: Add ctype.h**: With `isdigit` stub
3. **tree-sitter-bash scanner.c**: Uses `strcmp` and `isdigit`

These are simple C function stubs (return 0) since tree-sitter grammars
aren't needed for MCR trace replay — only for tracepoint expression parsing
in DB traces.

## Workaround for MCR-Only Build

For MCR trace replay, tree-sitter isn't needed. A feature flag
`no-tracepoints` could disable tree-sitter grammars to unblock the
WASM build for MCR-only replay. This is a potential M5 workaround.
