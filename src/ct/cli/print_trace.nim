## ct print -- Print trace events in human-readable format.
##
## Auto-detects the trace type:
## - MCR .ct files: prints summary info and delegates to ct-mcr
## - Materialized traces (trace.bin): reads metadata and event summaries
## - JSONL span manifests: parses and pretty-prints HTTP requests
## - Trace directories: scans for trace files within

import
  std/[os, json, strutils, strformat, options]

type
  TraceType* = enum
    ttUnknown
    ttMcrTrace       ## MCR .ct file
    ttMaterialized   ## trace.bin + trace_metadata.json (Ruby/Python/PHP)
    ttSpanManifest   ## JSONL span manifest (session_manifest.jsonl, codetracer_spans.jsonl)
    ttTraceDirectory ## Directory containing trace files

  PrintOptions* = object
    path*: string
    filter*: string        ## "calls", "steps", "http", "errors", ""
    function*: string      ## filter by function name
    limit*: int            ## max events to print (0 = unlimited)
    format*: string        ## "text", "json", "csv"
    verify*: bool          ## verify mode for CI smoke tests
    follow*: bool          ## follow mode (future: watch for new events)

proc detectTraceType*(path: string): TraceType =
  ## Determine the trace type from a file or directory path.
  ## Returns ttUnknown if the path does not exist or cannot be classified.
  if not fileExists(path) and not dirExists(path):
    return ttUnknown

  if fileExists(path):
    if path.endsWith(".ct"):
      return ttMcrTrace
    if path.endsWith(".jsonl"):
      return ttSpanManifest
    if path.endsWith(".bin"):
      return ttMaterialized
    # Peek at the first bytes to detect JSON lines
    try:
      let content = readFile(path)
      if content.len > 0 and content[0] == '{':
        return ttSpanManifest
    except CatchableError:
      discard
    return ttUnknown

  # Directory -- look for known marker files
  if fileExists(path / "trace.bin") or fileExists(path / "trace.json"):
    return ttMaterialized
  if fileExists(path / "session_manifest.jsonl") or
      fileExists(path / "codetracer_spans.jsonl"):
    return ttSpanManifest

  # Check for .ct files inside the directory
  for kind, file in walkDir(path):
    if kind == pcFile and file.endsWith(".ct"):
      return ttMcrTrace

  return ttTraceDirectory

proc printSpanManifest(path: string, opts: PrintOptions) =
  ## Pretty-print a JSONL span manifest (HTTP requests).
  let manifestPath =
    if fileExists(path):
      path
    elif fileExists(path / "session_manifest.jsonl"):
      path / "session_manifest.jsonl"
    elif fileExists(path / "codetracer_spans.jsonl"):
      path / "codetracer_spans.jsonl"
    else:
      echo "No span manifest found in: " & path
      return

  echo fmt"Span manifest: {manifestPath}"
  echo ""

  if opts.format == "csv":
    echo "method,url,status_code,duration_ms,status"
  elif opts.format != "json":
    # Text table header
    echo fmt"{"#":>4}  {"Method":<8} {"URL":<30} {"Status":<7} {"Duration":<10} {"Status":<6}"
    echo "-".repeat(75)

  var count = 0
  for line in lines(manifestPath):
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue

    try:
      let j = parseJson(trimmed)
      let meta = j{"metadata"}
      if meta == nil:
        continue

      let httpMethod = meta{"http.method"}.getStr("-")
      let url = meta{"http.url"}.getStr("-")
      let statusCode = meta{"http.status_code"}.getStr("-")
      let durationMs = meta{"http.duration_ms"}.getStr("-")
      let status = j{"status"}.getStr("-")

      # Apply filters
      if opts.filter == "errors" and status != "error":
        continue
      if opts.filter == "http" and httpMethod == "-":
        continue
      if opts.function.len > 0 and opts.function notin url:
        continue

      inc count
      if opts.limit > 0 and count > opts.limit:
        break

      if opts.format == "json":
        echo trimmed
      elif opts.format == "csv":
        echo fmt"{httpMethod},{url},{statusCode},{durationMs},{status}"
      else:
        echo fmt"{count:>4}  {httpMethod:<8} {url:<30} {statusCode:<7} {durationMs:>6}ms  {status:<6}"
    except JsonParsingError:
      continue

  if opts.format != "json" and opts.format != "csv":
    echo ""
    echo fmt"Total: {count} requests"

proc printMaterializedTrace(path: string, opts: PrintOptions) =
  ## Print events from a materialized trace (trace.bin + metadata).
  let traceDir = if dirExists(path): path else: parentDir(path)

  let metadataPath = traceDir / "trace_metadata.json"
  let tracePath =
    if fileExists(traceDir / "trace.bin"):
      traceDir / "trace.bin"
    elif fileExists(traceDir / "trace.json"):
      traceDir / "trace.json"
    else:
      ""

  # Print metadata summary
  if fileExists(metadataPath):
    try:
      let meta = parseJson(readFile(metadataPath))
      echo "Trace metadata:"
      echo fmt"  Program: {meta{""program""}.getStr(""unknown"")}"
      echo fmt"  Working dir: {meta{""workdir""}.getStr(""-"")}"
      echo fmt"  Format: {meta{""format""}.getStr(""-"")}"
      echo ""
    except CatchableError:
      discard

  # Print source file paths if available
  let pathsFile = traceDir / "trace_paths.json"
  if fileExists(pathsFile):
    try:
      let paths = parseJson(readFile(pathsFile))
      echo fmt"Source files: {paths.len}"
      for i in 0 ..< paths.len:
        if i < 5:
          echo fmt"  [{i}] {paths[i].getStr()}"
        elif i == 5:
          echo fmt"  ... and {paths.len - 5} more"
      echo ""
    except CatchableError:
      discard

  # Print event summary from trace_events.jsonl if available
  let eventsFile = traceDir / "trace_events.jsonl"
  if fileExists(eventsFile):
    var calls, steps, returns, variables = 0
    var printed = 0
    for line in lines(eventsFile):
      let trimmed = line.strip()
      if trimmed.len == 0:
        continue
      try:
        let ev = parseJson(trimmed)
        let evType = ev{"type"}.getStr("")
        case evType
        of "call": inc calls
        of "step": inc steps
        of "return": inc returns
        of "variable": inc variables
        else: discard

        # Apply filters
        if opts.filter.len > 0 and opts.filter != evType:
          continue
        if opts.function.len > 0:
          let funcName = ev{"function"}.getStr("")
          if opts.function notin funcName:
            continue

        inc printed
        if opts.limit > 0 and printed > opts.limit:
          continue

        if opts.format == "json":
          echo trimmed
        elif opts.format == "csv":
          echo fmt"{evType},{ev{""function""}.getStr(""-"")},{ev{""file""}.getStr(""-"")},{ev{""line""}.getInt(0)}"
      except CatchableError:
        discard
    if opts.format != "json" and opts.format != "csv":
      echo "Events:"
      echo fmt"  Calls:     {calls}"
      echo fmt"  Steps:     {steps}"
      echo fmt"  Returns:   {returns}"
      echo fmt"  Variables: {variables}"
      echo fmt"  Total:     {calls + steps + returns + variables}"
    return

  if tracePath.len > 0:
    let size = getFileSize(tracePath)
    echo fmt"Trace file: {tracePath} ({size} bytes)"
    echo "(Binary trace -- use ct replay to inspect events)"
  else:
    echo "No trace events file found in: " & traceDir

proc printMcrTrace(path: string, opts: PrintOptions) =
  ## Print info about an MCR .ct trace file.
  echo fmt"MCR trace: {path}"
  let size = getFileSize(path)
  echo fmt"  Size: {size} bytes ({size div 1024} KB)"
  echo ""
  echo "(Use 'ct-mcr trace info " & path & "' for detailed event analysis)"
  echo "(Use 'ct-mcr trace events " & path & "' to dump individual events)"

proc printTraceDirectory(path: string, opts: PrintOptions) =
  ## Scan a directory for traces and print a summary.
  echo fmt"Trace directory: {path}"
  echo ""

  var traceCount = 0
  for kind, entry in walkDir(path):
    if kind == pcDir:
      let detected = detectTraceType(entry)
      if detected != ttUnknown and detected != ttTraceDirectory:
        inc traceCount
        let name = extractFilename(entry)
        echo fmt"  [{traceCount}] {name} ({detected})"
    elif kind == pcFile and entry.endsWith(".ct"):
      inc traceCount
      let name = extractFilename(entry)
      echo fmt"  [{traceCount}] {name} (ttMcrTrace)"

  if traceCount == 0:
    echo "  No traces found."
  else:
    echo ""
    echo fmt"Total: {traceCount} traces"
    echo "Use 'ct print <trace-path>' to inspect a specific trace."

type
  VerifyResult* = object
    ## Result of trace verification, used by ``--verify`` for CI smoke tests.
    valid*: bool
    traceType*: TraceType
    eventCount*: int
    callCount*: int
    stepCount*: int
    httpRequestCount*: int
    sourceFileCount*: int
    errors*: seq[string]

proc verifySpanManifest(path: string): VerifyResult =
  ## Verify a JSONL span manifest contains valid HTTP request entries.
  result.traceType = ttSpanManifest
  let manifestPath =
    if fileExists(path): path
    elif fileExists(path / "session_manifest.jsonl"):
      path / "session_manifest.jsonl"
    elif fileExists(path / "codetracer_spans.jsonl"):
      path / "codetracer_spans.jsonl"
    else:
      result.errors.add("No span manifest found")
      return

  for line in lines(manifestPath):
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    try:
      let j = parseJson(trimmed)
      let meta = j{"metadata"}
      if meta != nil and meta.hasKey("http.method"):
        result.httpRequestCount += 1
      else:
        result.errors.add("Span missing http.method metadata")
    except CatchableError:
      result.errors.add("Malformed JSON line")

  result.eventCount = result.httpRequestCount
  result.valid = result.httpRequestCount > 0 and result.errors.len == 0

proc verifyMaterializedTrace(path: string): VerifyResult =
  ## Verify a materialized trace directory has the expected files and events.
  result.traceType = ttMaterialized
  let traceDir = if dirExists(path): path else: parentDir(path)

  # Check trace files exist
  let hasMetadata = fileExists(traceDir / "trace_metadata.json")
  let hasEvents = fileExists(traceDir / "trace.bin") or
                  fileExists(traceDir / "trace.json") or
                  fileExists(traceDir / "trace_events.jsonl")
  let hasPaths = fileExists(traceDir / "trace_paths.json")

  if not hasMetadata:
    result.errors.add("Missing trace_metadata.json")
  if not hasEvents:
    result.errors.add(
      "Missing trace events file " &
      "(trace.bin/trace.json/trace_events.jsonl)")
  if not hasPaths:
    result.errors.add("Missing trace_paths.json")

  # Count events from JSONL if available
  if fileExists(traceDir / "trace_events.jsonl"):
    for line in lines(traceDir / "trace_events.jsonl"):
      let trimmed = line.strip()
      if trimmed.len == 0: continue
      try:
        let ev = parseJson(trimmed)
        result.eventCount += 1
        let evType = ev{"type"}.getStr("")
        case evType
        of "call": result.callCount += 1
        of "step": result.stepCount += 1
        else: discard
      except CatchableError:
        discard
  elif fileExists(traceDir / "trace.bin"):
    # Binary trace -- check file size as a proxy for content
    let size = getFileSize(traceDir / "trace.bin")
    if size > 100:
      result.eventCount = 1  # At least something is there
    else:
      result.errors.add(
        "trace.bin is suspiciously small (" &
        $size & " bytes)")

  # Count source files
  if hasPaths:
    try:
      let paths = parseJson(readFile(traceDir / "trace_paths.json"))
      result.sourceFileCount = paths.len
    except CatchableError:
      discard

  result.valid = result.errors.len == 0 and result.eventCount > 0

proc verifyMcrTrace(path: string): VerifyResult =
  ## Verify an MCR .ct trace file exists and has reasonable size.
  result.traceType = ttMcrTrace
  if not fileExists(path):
    result.errors.add("File not found: " & path)
    return
  let size = getFileSize(path)
  if size < 100:
    result.errors.add(
      "Trace file suspiciously small (" &
      $size & " bytes)")
  else:
    result.eventCount = 1  # We know events exist based on file size
    result.valid = true

proc verifyTraceDirectory(path: string): VerifyResult =
  ## Verify a directory containing traces or span manifests.
  result.traceType = ttTraceDirectory
  var traceCount = 0

  # Check for span manifest with HTTP requests
  for candidate in [
    path / "session_manifest.jsonl",
    path / "codetracer_spans.jsonl",
  ]:
    if fileExists(candidate):
      let subResult = verifySpanManifest(candidate)
      result.httpRequestCount += subResult.httpRequestCount

  # Check for individual trace directories
  for kind, entry in walkDir(path):
    if kind == pcDir:
      let subType = detectTraceType(entry)
      if subType == ttMaterialized:
        let subResult = verifyMaterializedTrace(entry)
        result.eventCount += subResult.eventCount
        result.callCount += subResult.callCount
        result.stepCount += subResult.stepCount
        traceCount += 1

  # Check for .ct files
  for kind, entry in walkDir(path):
    if kind == pcFile and entry.endsWith(".ct"):
      traceCount += 1
      result.eventCount += 1

  if traceCount == 0 and result.httpRequestCount == 0:
    result.errors.add(
      "No traces or requests found in directory")

  result.valid = result.errors.len == 0 and
    (result.eventCount > 0 or result.httpRequestCount > 0)

proc runVerify*(opts: PrintOptions): int =
  ## Verify a trace and return exit code (0=pass, 1=fail).
  ## Designed for CI smoke tests:
  ##   ct print --verify trace-out/ || exit 1
  let traceType = detectTraceType(opts.path)

  let verifyResult = case traceType
    of ttSpanManifest:
      verifySpanManifest(opts.path)
    of ttMaterialized:
      verifyMaterializedTrace(opts.path)
    of ttMcrTrace:
      verifyMcrTrace(opts.path)
    of ttTraceDirectory:
      verifyTraceDirectory(opts.path)
    of ttUnknown:
      VerifyResult(
        valid: false,
        errors: @[
          "Cannot detect trace type: " & opts.path])

  # Print concise summary -- one line per metric, PASS/FAIL at end
  echo "Trace verification: " & opts.path
  echo "  Type:           " & $verifyResult.traceType
  echo "  Events:         " & $verifyResult.eventCount
  if verifyResult.callCount > 0:
    echo "  Function calls: " & $verifyResult.callCount
  if verifyResult.stepCount > 0:
    echo "  Steps:          " & $verifyResult.stepCount
  if verifyResult.httpRequestCount > 0:
    echo "  HTTP requests:  " & $verifyResult.httpRequestCount
  if verifyResult.sourceFileCount > 0:
    echo "  Source files:   " & $verifyResult.sourceFileCount

  if verifyResult.errors.len > 0:
    echo "  Errors:"
    for err in verifyResult.errors:
      echo "    - " & err

  if verifyResult.valid:
    echo "  Status:         PASS"
    return 0
  else:
    echo "  Status:         FAIL"
    return 1

proc runPrint*(opts: PrintOptions) =
  ## Main entry point for the print command.
  if opts.verify:
    let exitCode = runVerify(opts)
    quit(exitCode)

  let traceType = detectTraceType(opts.path)

  case traceType
  of ttSpanManifest:
    printSpanManifest(opts.path, opts)
  of ttMaterialized:
    printMaterializedTrace(opts.path, opts)
  of ttMcrTrace:
    printMcrTrace(opts.path, opts)
  of ttTraceDirectory:
    printTraceDirectory(opts.path, opts)
  of ttUnknown:
    echo "Error: Cannot detect trace type for: " & opts.path
    echo ""
    echo "Expected one of:"
    echo "  - A .ct file (MCR trace)"
    echo "  - A directory with trace.bin/trace.json (materialized trace)"
    echo "  - A .jsonl file (span manifest)"
    echo "  - A directory containing traces"
    quit(1)
