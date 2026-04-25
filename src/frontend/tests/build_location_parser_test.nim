## Unit tests for multi-language build output error location parsing.
##
## Covers: Nim, TypeScript, GCC/Clang, Rust (cargo), Go, and Python formats.

import
  std/[unittest, strutils],
  ../ui/build_location_parser

suite "parseBuildLocation — Nim format":
  test "nim error with line and column":
    let r = parseBuildLocation("/home/user/project/src/main.nim(10, 5) Error: undeclared identifier")
    check r.found
    check r.path == "/home/user/project/src/main.nim"
    check r.line == 10
    check r.col == 5
    check r.severity == SevError

  test "nim error with line only":
    let r = parseBuildLocation("/home/user/src/lib.nim(42) Error: type mismatch")
    check r.found
    check r.path == "/home/user/src/lib.nim"
    check r.line == 42
    check r.col == -1
    check r.severity == SevError

  test "nim warning":
    let r = parseBuildLocation("/tmp/test.nim(7, 1) Warning: use {.push warning[UnusedImport]:off.}")
    check r.found
    check r.path == "/tmp/test.nim"
    check r.line == 7
    check r.col == 1
    check r.severity == SevWarning

suite "parseBuildLocation — TypeScript format":
  test "typescript error":
    let r = parseBuildLocation("src/index.ts(42,5): error TS2304: Cannot find name 'foo'.")
    check r.found
    check r.path == "src/index.ts"
    check r.line == 42
    check r.col == 5
    check r.severity == SevError
    check r.message.contains("Cannot find name")

  test "typescript error without column":
    let r = parseBuildLocation("app.tsx(100): error TS1005: ';' expected.")
    check r.found
    check r.path == "app.tsx"
    check r.line == 100
    check r.col == -1
    check r.severity == SevError

suite "parseBuildLocation — GCC/Clang format":
  test "gcc error with line and column":
    let r = parseBuildLocation("file.c:42:5: error: expected ';' before '}' token")
    check r.found
    check r.path == "file.c"
    check r.line == 42
    check r.col == 5
    check r.severity == SevError
    check r.message.contains("expected ';'")

  test "gcc warning":
    let r = parseBuildLocation("file.c:42:5: warning: unused variable 'x' [-Wunused-variable]")
    check r.found
    check r.path == "file.c"
    check r.line == 42
    check r.col == 5
    check r.severity == SevWarning

  test "clang note":
    let r = parseBuildLocation("include/header.h:10:3: note: expanded from macro 'FOO'")
    check r.found
    check r.path == "include/header.h"
    check r.line == 10
    check r.col == 3
    check r.severity == SevInfo

  test "gcc with absolute path":
    let r = parseBuildLocation("/usr/include/stdio.h:27:10: error: something wrong")
    check r.found
    check r.path == "/usr/include/stdio.h"
    check r.line == 27
    check r.col == 10
    check r.severity == SevError

suite "parseBuildLocation — Rust (cargo) format":
  test "rust arrow with line and column":
    let r = parseBuildLocation(" --> src/main.rs:42:5")
    check r.found
    check r.path == "src/main.rs"
    check r.line == 42
    check r.col == 5
    check r.severity == SevError

  test "rust arrow with only line":
    let r = parseBuildLocation("  --> src/lib.rs:100")
    check r.found
    check r.path == "src/lib.rs"
    check r.line == 100
    check r.col == -1

  test "rust arrow no leading spaces":
    let r = parseBuildLocation("--> tests/integration.rs:7:1")
    check r.found
    check r.path == "tests/integration.rs"
    check r.line == 7
    check r.col == 1

suite "parseBuildLocation — Go format":
  test "go error with relative path":
    let r = parseBuildLocation("./main.go:42:5: undefined: fmt.Printlm")
    check r.found
    check r.path == "./main.go"
    check r.line == 42
    check r.col == 5
    check r.message.contains("undefined")

  test "go error without column":
    let r = parseBuildLocation("./cmd/server.go:15: imported and not used")
    check r.found
    check r.path == "./cmd/server.go"
    check r.line == 15
    check r.col == -1

suite "parseBuildLocation — Python format":
  test "python traceback with module":
    let r = parseBuildLocation("  File \"script.py\", line 42, in <module>")
    check r.found
    check r.path == "script.py"
    check r.line == 42
    check r.col == -1
    check r.message.contains("<module>")

  test "python traceback with function":
    let r = parseBuildLocation("  File \"/home/user/app.py\", line 100, in main")
    check r.found
    check r.path == "/home/user/app.py"
    check r.line == 100

  test "python traceback bare":
    let r = parseBuildLocation("File \"test.py\", line 1")
    check r.found
    check r.path == "test.py"
    check r.line == 1

suite "parseBuildLocation — non-matching lines":
  test "empty string":
    check not parseBuildLocation("").found

  test "plain text":
    check not parseBuildLocation("Compiling project...").found

  test "rust error header without location":
    check not parseBuildLocation("error[E0308]: mismatched types").found

  test "nim hint is not matched by matchLocation but parseBuildLocation may match":
    # parseBuildLocation itself does not filter hints -- that is done at
    # the matchLocation level. Verify the parser still returns a result
    # for a line that looks like a Nim hint with a location.
    let r = parseBuildLocation("/tmp/x.nim(1, 1) Hint: used config file")
    check r.found
    check r.severity == SevInfo

suite "parseBuildLocation — edge cases":
  test "path with spaces in parenthesised format":
    let r = parseBuildLocation("my project/src/app.nim(5, 3) Error: type mismatch")
    check r.found
    check r.path == "my project/src/app.nim"
    check r.line == 5
    check r.col == 3

  test "colon format path with dot-only (no slash)":
    let r = parseBuildLocation("main.c:10:1: error: something")
    check r.found
    check r.path == "main.c"
    check r.line == 10

  test "no file extension — should not match colon format":
    # A line like `make:10: recipe failed` should not produce a match
    # because `make` has no dot, slash, or backslash.
    check not parseBuildLocation("make: recipe failed").found

suite "inferSeverity":
  test "error keyword":
    check inferSeverity("error: something broke") == SevError

  test "warning keyword":
    check inferSeverity("warning: this is suspicious") == SevWarning

  test "note keyword":
    check inferSeverity("note: see declaration") == SevInfo

  test "hint keyword":
    check inferSeverity("Hint: configuration loaded") == SevInfo

  test "no keyword defaults to error":
    check inferSeverity("unexpected token") == SevError
