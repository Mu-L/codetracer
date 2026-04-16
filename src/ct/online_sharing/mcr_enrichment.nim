## MCR trace detection and portable enrichment for upload.
##
## Before uploading, MCR traces (stored in the CTFS container format) need
## to be enriched with binaries and debug symbols via `ct-mcr export --portable`.
## This module provides:
##
## - CTFS magic detection (5-byte header: C0 DE 72 AC E2)
## - ct-mcr binary discovery (env var, sibling, PATH)
## - Enrichment subprocess invocation
##
## The detection intentionally avoids importing any ct_replayer or ct_recorder
## modules — those live in the codetracer-native-recorder repo. We rely solely
## on the 5-byte CTFS magic header to identify MCR traces.

import std/[os, osproc, strutils, strformat]

const
  ## CTFS container magic bytes.
  ## Reference: codetracer-native-recorder/ct_recorder/src/ct_recorder/ctfs_nim.nim
  CtfsMagic*: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]

proc hasCtfsMagic(path: string): bool =
  ## Read the first 5 bytes of `path` and check against the CTFS magic.
  ## Returns false if the file is too small, unreadable, or does not match.
  var f: File
  if not open(f, path, fmRead):
    return false
  defer: f.close()
  var buf: array[5, byte]
  let bytesRead = f.readBytes(buf, 0, 5)
  if bytesRead < 5:
    return false
  buf[0] == CtfsMagic[0] and
  buf[1] == CtfsMagic[1] and
  buf[2] == CtfsMagic[2] and
  buf[3] == CtfsMagic[3] and
  buf[4] == CtfsMagic[4]

proc findCtFileInFolder*(folder: string): string =
  ## Scan `folder` for a file ending in `.ct` that has the CTFS magic header.
  ## Returns the path to the first matching file, or "" if none found.
  ## Only checks immediate children (not recursive).
  if not dirExists(folder):
    return ""
  for kind, path in walkDir(folder):
    if kind in {pcFile, pcLinkToFile}:
      if path.endsWith(".ct") and hasCtfsMagic(path):
        return path
  return ""

proc findCtMcrBinary*(): string =
  ## Locate the ct-mcr binary. Search order:
  ##   1. $CODETRACER_CT_MCR_CMD environment variable
  ##   2. Sibling of the running ct binary (same directory)
  ##   3. Anywhere on $PATH (via `which`)
  ##
  ## Returns the absolute path, or "" if not found.
  let envCmd = getEnv("CODETRACER_CT_MCR_CMD")
  if envCmd.len > 0 and fileExists(envCmd):
    return envCmd

  let siblingPath = getAppDir() / "ct-mcr"
  if fileExists(siblingPath):
    return siblingPath

  # Fall back to PATH lookup.
  let (output, exitCode) = execCmdEx("which ct-mcr")
  if exitCode == 0:
    let resolved = output.strip()
    if resolved.len > 0 and fileExists(resolved):
      return resolved

  return ""

proc enrichMcrTraceIfNeeded*(outputFolder: string, noPortable: bool = false): bool =
  ## If `outputFolder` contains an MCR trace (.ct file with CTFS magic), run
  ## `ct-mcr export --portable` to add binaries and debug symbols in-place.
  ##
  ## Returns true if enrichment was performed successfully.
  ##
  ## When `noPortable` is true, enrichment is skipped unconditionally
  ## (for users who want to upload a lightweight trace).
  ##
  ## If ct-mcr is not installed, the function prints a warning and returns
  ## false — the upload continues with the non-enriched trace.
  if noPortable:
    return false

  let ctFilePath = findCtFileInFolder(outputFolder)
  if ctFilePath.len == 0:
    # No CTFS .ct file found — not an MCR trace, nothing to enrich.
    return false

  let ctMcr = findCtMcrBinary()
  if ctMcr.len == 0:
    echo "WARNING: MCR trace detected but ct-mcr binary not found."
    echo "  The trace will be uploaded without portable binaries/symbols."
    echo "  Install ct-mcr or set CODETRACER_CT_MCR_CMD to enable enrichment."
    return false

  # Run ct-mcr export --portable in-place. The --portable flag causes ct-mcr
  # to read the .ct, resolve referenced binaries from the local system, and
  # write them back into the same .ct container.
  #
  # Usage: ct-mcr export --portable -o <output.ct> <input.ct>
  # We write to a temp file first, then replace the original to avoid
  # corrupting the trace on failure.
  let enrichedPath = ctFilePath & ".portable"
  let cmd = fmt"{ctMcr.quoteShell} export --portable -o {enrichedPath.quoteShell} {ctFilePath.quoteShell}"
  let (output, exitCode) = execCmdEx(cmd)

  if exitCode != 0:
    echo "WARNING: ct-mcr export --portable failed (exit code " & $exitCode & ")."
    echo "  Output: " & output.strip()
    echo "  The trace will be uploaded without portable binaries/symbols."
    # Clean up the partial output, if any.
    if fileExists(enrichedPath):
      try: removeFile(enrichedPath)
      except OSError: discard
    return false

  # Replace the original .ct with the enriched version.
  try:
    moveFile(enrichedPath, ctFilePath)
  except OSError as e:
    echo "WARNING: failed to replace trace with enriched version: " & e.msg
    if fileExists(enrichedPath):
      try: removeFile(enrichedPath)
      except OSError: discard
    return false

  return true
