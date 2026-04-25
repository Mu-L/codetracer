## Multi-language build output error location parser.
##
## Parses error/warning locations from build output lines produced by:
## - Nim: `path/file.nim(line, col) severity: message`
## - TypeScript: `src/index.ts(42,5): error TS2304: message`
## - Rust (cargo): ` --> src/main.rs:42:5`
## - Python: `  File "script.py", line 42, in <module>`
## - GCC/Clang: `file.c:42:5: error: expected ';' ...`
## - Go: `./main.go:42:5: undefined: fmt.Printlm`
##
## This module is intentionally free of UI / framework dependencies so that
## it can be imported both by the build panel and by unit tests.

import std/strutils

type
  BuildSeverity* = enum
    ## Severity level extracted from a build output line.
    SevError,
    SevWarning,
    SevInfo

  ParsedBuildLocation* = object
    ## A parsed error/warning location from a build output line.
    ## `found` is true when the line matched one of the known patterns.
    found*: bool
    path*: string
    line*: int
    col*: int          ## -1 when the column is not present in the pattern
    severity*: BuildSeverity
    message*: string   ## the remaining message text (may be empty)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc inferSeverity*(text: string): BuildSeverity =
  ## Infer a severity from free-form message text.
  ## Falls back to SevError when no keyword is recognised.
  let lower = text.toLowerAscii
  if "warning" in lower:
    return SevWarning
  if "info" in lower or "note" in lower or "hint" in lower:
    return SevInfo
  return SevError

proc allDigits*(s: string): bool =
  ## Return true when every character in `s` is a decimal digit.
  if s.len == 0:
    return false
  for ch in s:
    if ch < '0' or ch > '9':
      return false
  return true

# ---------------------------------------------------------------------------
# Individual pattern parsers
#
# Each proc returns a ParsedBuildLocation with `found = true` on match.
# The order in which these are tried matters -- more specific patterns
# (like Rust's ` --> `) come first so that ambiguous lines are not
# claimed by a greedy generic pattern.
# ---------------------------------------------------------------------------

proc parseNimLocation*(raw: string): ParsedBuildLocation =
  ## Nim format: path/file.nim(line, col) severity: message
  ## Also matches TypeScript: src/index.ts(42,5): error TS2304: message
  ##
  ## We look for `(<digits>,<digits>)` or `(<digits>)` after a file path.
  let parenLeft = raw.find("(")
  if parenLeft == -1 or parenLeft == 0:
    return ParsedBuildLocation(found: false)

  let parenRight = raw.find(")", parenLeft)
  if parenRight == -1:
    return ParsedBuildLocation(found: false)

  let inside = raw[parenLeft + 1 ..< parenRight]
  let comma = inside.find(",")

  var lineNum = -1
  var colNum = -1

  if comma != -1:
    let linePart = inside[0 ..< comma].strip
    let colPart = inside[comma + 1 .. ^1].strip
    if not allDigits(linePart):
      return ParsedBuildLocation(found: false)
    lineNum = linePart.parseInt
    if allDigits(colPart):
      colNum = colPart.parseInt
    else:
      return ParsedBuildLocation(found: false)
  else:
    let linePart = inside.strip
    if not allDigits(linePart):
      return ParsedBuildLocation(found: false)
    lineNum = linePart.parseInt

  let path = raw[0 ..< parenLeft]
  let rest = if parenRight + 1 < raw.len: raw[parenRight + 1 .. ^1].strip else: ""
  let severity = inferSeverity(rest)

  return ParsedBuildLocation(
    found: true,
    path: path,
    line: lineNum,
    col: colNum,
    severity: severity,
    message: rest)

proc parseRustLocation*(raw: string): ParsedBuildLocation =
  ## Rust (cargo) format:  --> src/main.rs:42:5
  ## The line starts with optional whitespace followed by `-->`.
  let stripped = raw.strip
  if not stripped.startsWith("-->"):
    return ParsedBuildLocation(found: false)

  let rest = stripped[3 .. ^1].strip  # after "-->"

  # rest should be  path:line:col
  # Split from the right to handle paths containing colons (e.g. Windows).
  # We need at least one colon for path:line and optionally path:line:col.
  let lastColon = rest.rfind(":")
  if lastColon == -1:
    return ParsedBuildLocation(found: false)

  let afterLast = rest[lastColon + 1 .. ^1]
  if not allDigits(afterLast):
    return ParsedBuildLocation(found: false)

  let beforeLast = rest[0 ..< lastColon]
  let secondColon = beforeLast.rfind(":")
  if secondColon == -1:
    # Only path:line
    return ParsedBuildLocation(
      found: true,
      path: beforeLast,
      line: afterLast.parseInt,
      col: -1,
      severity: SevError,
      message: "")

  let afterSecond = beforeLast[secondColon + 1 .. ^1]
  if allDigits(afterSecond):
    # path:line:col
    return ParsedBuildLocation(
      found: true,
      path: beforeLast[0 ..< secondColon],
      line: afterSecond.parseInt,
      col: afterLast.parseInt,
      severity: SevError,
      message: "")
  else:
    # The middle segment is not digits, so treat as path:line
    return ParsedBuildLocation(
      found: true,
      path: beforeLast,
      line: afterLast.parseInt,
      col: -1,
      severity: SevError,
      message: "")

proc parsePythonLocation*(raw: string): ParsedBuildLocation =
  ## Python format:   File "script.py", line 42, in <module>
  ## Also handles:    File "script.py", line 42
  let stripped = raw.strip
  if not stripped.startsWith("File \""):
    return ParsedBuildLocation(found: false)

  let quoteEnd = stripped.find("\"", 6)  # closing quote after `File "`
  if quoteEnd == -1:
    return ParsedBuildLocation(found: false)

  let path = stripped[6 ..< quoteEnd]

  # After the closing quote we expect `, line <number>`
  let afterQuote = stripped[quoteEnd + 1 .. ^1].strip
  if not afterQuote.startsWith(", line "):
    return ParsedBuildLocation(found: false)

  let lineStr = afterQuote[7 .. ^1]  # after ", line "
  # lineStr may contain more text after the number (", in <module>")
  var numEnd = 0
  while numEnd < lineStr.len and lineStr[numEnd] >= '0' and lineStr[numEnd] <= '9':
    inc numEnd

  if numEnd == 0:
    return ParsedBuildLocation(found: false)

  let lineNum = lineStr[0 ..< numEnd].parseInt
  let rest = if numEnd < lineStr.len: lineStr[numEnd .. ^1].strip else: ""

  return ParsedBuildLocation(
    found: true,
    path: path,
    line: lineNum,
    col: -1,
    severity: SevError,
    message: rest)

proc parseColonLocation*(raw: string): ParsedBuildLocation =
  ## Generic colon-separated format used by GCC/Clang and Go:
  ##   file.c:42:5: error: expected ';' before '}' token
  ##   ./main.go:42:5: undefined: fmt.Printlm
  ##
  ## Pattern: <path>:<line>:<col>: <rest>  or  <path>:<line>: <rest>
  ##
  ## To avoid false positives we require:
  ##   - the path portion to contain a dot (file extension) or a slash,
  ##   - <line> to be all digits.

  # Find the first colon that could end the path part.
  # Skip a leading drive letter on Windows (e.g. C:).
  var searchStart = 0
  if raw.len >= 3 and raw[1] == ':' and raw[0].isAlphaAscii:
    searchStart = 2

  let firstColon = raw.find(":", searchStart)
  if firstColon == -1:
    return ParsedBuildLocation(found: false)

  let path = raw[0 ..< firstColon]
  # Path heuristic: must look like a file reference.
  if not ("." in path or "/" in path or "\\" in path):
    return ParsedBuildLocation(found: false)

  let afterPath = raw[firstColon + 1 .. ^1]
  let secondColon = afterPath.find(":")
  if secondColon == -1:
    return ParsedBuildLocation(found: false)

  let lineStr = afterPath[0 ..< secondColon]
  if not allDigits(lineStr):
    return ParsedBuildLocation(found: false)

  let lineNum = lineStr.parseInt

  let afterLine = afterPath[secondColon + 1 .. ^1]
  let thirdColon = afterLine.find(":")
  if thirdColon != -1:
    let colStr = afterLine[0 ..< thirdColon].strip
    if allDigits(colStr):
      let rest = afterLine[thirdColon + 1 .. ^1].strip
      let severity = inferSeverity(rest)
      return ParsedBuildLocation(
        found: true,
        path: path,
        line: lineNum,
        col: colStr.parseInt,
        severity: severity,
        message: rest)

  # Only path:line: rest  (no column)
  let rest = afterLine.strip
  let severity = inferSeverity(rest)
  return ParsedBuildLocation(
    found: true,
    path: path,
    line: lineNum,
    col: -1,
    severity: severity,
    message: rest)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc parseBuildLocation*(raw: string): ParsedBuildLocation =
  ## Try to parse an error/warning location from a build output line.
  ##
  ## Patterns are tried in order from most specific to most generic:
  ##   1. Rust (`-->`)
  ##   2. Python (`File "..."`)
  ##   3. Nim / TypeScript (`path(line,col)`)
  ##   4. GCC / Clang / Go (`path:line:col:`)

  # Rust arrow pattern is unambiguous -- try first.
  result = parseRustLocation(raw)
  if result.found:
    return

  # Python traceback format is also distinctive.
  result = parsePythonLocation(raw)
  if result.found:
    return

  # Nim / TypeScript parenthesised location.
  result = parseNimLocation(raw)
  if result.found:
    return

  # Generic colon format (GCC, Clang, Go, etc.).
  result = parseColonLocation(raw)
  if result.found:
    return

  return ParsedBuildLocation(found: false)
