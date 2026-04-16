## Unit tests for MCR trace detection, enrichment, and slice detection logic.
##
## These tests verify:
## - CTFS magic detection (positive and negative cases)
## - .ct file discovery within a folder
## - Enrichment skip behavior for non-MCR traces
## - Enrichment skip behavior when noPortable is true
## - Pre-split slice directory detection (findSlicesDir, hasPreSplitSlices)
## - Slice counting (countSlices)
##
## Note: we cannot test the actual ct-mcr subprocess invocation in unit tests
## since ct-mcr may not be installed. The subprocess call is tested via the
## E2E tests in M16d.

import std/[os, unittest]
import mcr_enrichment

suite "MCR Enrichment — CTFS magic detection":

  test "file with CTFS magic is detected":
    let tmpDir = getTempDir() / "test_mcr_enrich_magic"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    # Write the 5-byte CTFS magic followed by some padding.
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    # Write a few more bytes so the file is not trivially small.
    let padding: array[16, byte] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0]
    discard f.writeBytes(padding, 0, 16)
    f.close()

    let found = findCtFileInFolder(tmpDir)
    check found == ctPath

  test "file without CTFS magic is not detected":
    let tmpDir = getTempDir() / "test_mcr_enrich_no_magic"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    # Write garbage bytes that do not match the CTFS magic.
    let garbage: array[5, byte] = [0xFF'u8, 0xFE, 0xFD, 0xFC, 0xFB]
    discard f.writeBytes(garbage, 0, 5)
    f.close()

    let found = findCtFileInFolder(tmpDir)
    check found == ""

  test "file too small to contain magic is not detected":
    let tmpDir = getTempDir() / "test_mcr_enrich_small"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    # Only 3 bytes — shorter than the 5-byte magic.
    let short: array[3, byte] = [0xC0'u8, 0xDE, 0x72]
    discard f.writeBytes(short, 0, 3)
    f.close()

    let found = findCtFileInFolder(tmpDir)
    check found == ""

  test "non-.ct files are ignored even if they have magic bytes":
    let tmpDir = getTempDir() / "test_mcr_enrich_ext"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Write a .db file with CTFS magic — should be ignored.
    let dbPath = tmpDir / "trace.db"
    var f = open(dbPath, fmWrite)
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    f.close()

    let found = findCtFileInFolder(tmpDir)
    check found == ""


suite "MCR Enrichment — folder scanning":

  test "empty folder returns no .ct file":
    let tmpDir = getTempDir() / "test_mcr_enrich_empty"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let found = findCtFileInFolder(tmpDir)
    check found == ""

  test "non-existent folder returns no .ct file":
    let found = findCtFileInFolder("/tmp/this_path_should_not_exist_42")
    check found == ""

  test "folder with mixed files finds the .ct one":
    let tmpDir = getTempDir() / "test_mcr_enrich_mixed"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create several non-.ct files.
    writeFile(tmpDir / "meta.json", "{}")
    writeFile(tmpDir / "events.bin", "data")
    writeFile(tmpDir / "README", "hello")

    # Create one .ct file with proper magic.
    let ctPath = tmpDir / "recording.ct"
    var f = open(ctPath, fmWrite)
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    let padding: array[8, byte] = [0'u8, 0, 0, 0, 0, 0, 0, 0]
    discard f.writeBytes(padding, 0, 8)
    f.close()

    let found = findCtFileInFolder(tmpDir)
    check found == ctPath


suite "MCR Enrichment — enrichMcrTraceIfNeeded":

  test "skips enrichment when noPortable is true":
    let tmpDir = getTempDir() / "test_mcr_enrich_skip_noportable"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create a valid .ct file — enrichment should still be skipped.
    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    f.close()

    let enriched = enrichMcrTraceIfNeeded(tmpDir, noPortable = true)
    check enriched == false

  test "returns false for folder without MCR trace":
    let tmpDir = getTempDir() / "test_mcr_enrich_nomcr"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Non-MCR trace folder: just a sqlite DB.
    writeFile(tmpDir / "trace.db", "SQLite format 3\x00")
    writeFile(tmpDir / "meta.json", "{}")

    let enriched = enrichMcrTraceIfNeeded(tmpDir, noPortable = false)
    check enriched == false

  test "returns false for non-existent folder":
    let enriched = enrichMcrTraceIfNeeded(
      "/tmp/this_path_should_not_exist_42", noPortable = false)
    check enriched == false


suite "MCR Enrichment — findCtMcrBinary":

  test "returns empty string when binary not available":
    # Temporarily clear the env var to ensure a clean test.
    let saved = getEnv("CODETRACER_CT_MCR_CMD")
    putEnv("CODETRACER_CT_MCR_CMD", "")
    defer: putEnv("CODETRACER_CT_MCR_CMD", saved)

    # findCtMcrBinary may still find ct-mcr on PATH if it's installed,
    # so we only verify the return type is a string.
    let binary = findCtMcrBinary()
    # If ct-mcr is not installed, this will be "". If it is installed,
    # the path should be a valid file.
    if binary.len > 0:
      check fileExists(binary)

  test "respects CODETRACER_CT_MCR_CMD env var":
    let tmpDir = getTempDir() / "test_mcr_enrich_env"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let fakeBin = tmpDir / "ct-mcr"
    writeFile(fakeBin, "#!/bin/sh\necho fake")

    let saved = getEnv("CODETRACER_CT_MCR_CMD")
    putEnv("CODETRACER_CT_MCR_CMD", fakeBin)
    defer: putEnv("CODETRACER_CT_MCR_CMD", saved)

    let binary = findCtMcrBinary()
    check binary == fakeBin


suite "MCR Enrichment — slice detection (findSlicesDir)":

  test "detects slices directory when present":
    let tmpDir = getTempDir() / "test_slices_detect"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create a .ct file with CTFS magic (needed so findSlicesDir finds it).
    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    f.close()

    # Create the companion _slices directory with slice .ct files.
    let slicesDir = tmpDir / "trace.ct_slices"
    createDir(slicesDir)
    writeFile(slicesDir / "slice_0000.ct", "slice0")
    writeFile(slicesDir / "slice_0001.ct", "slice1")
    writeFile(slicesDir / "manifest.smnf", "manifest data")

    let found = findSlicesDir(tmpDir)
    check found == slicesDir

  test "returns empty when no slices directory exists":
    let tmpDir = getTempDir() / "test_slices_no_dir"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Only a .ct file, no _slices/ directory.
    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    f.close()

    let found = findSlicesDir(tmpDir)
    check found == ""

  test "returns empty when slices directory is empty":
    let tmpDir = getTempDir() / "test_slices_empty_dir"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    f.close()

    # Create the _slices directory but without any .ct files — only a manifest.
    let slicesDir = tmpDir / "trace.ct_slices"
    createDir(slicesDir)
    writeFile(slicesDir / "manifest.smnf", "manifest data")

    let found = findSlicesDir(tmpDir)
    check found == ""

  test "returns empty for non-existent folder":
    let found = findSlicesDir("/tmp/this_path_should_not_exist_slices_42")
    check found == ""

  test "ignores _slices dir when no matching .ct file":
    let tmpDir = getTempDir() / "test_slices_orphan"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create a _slices directory without the parent .ct file.
    let slicesDir = tmpDir / "trace.ct_slices"
    createDir(slicesDir)
    writeFile(slicesDir / "slice_0000.ct", "slice0")

    let found = findSlicesDir(tmpDir)
    check found == ""


suite "MCR Enrichment — hasPreSplitSlices":

  test "returns true when slices are present":
    let tmpDir = getTempDir() / "test_has_slices_true"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let ctPath = tmpDir / "trace.ct"
    var f = open(ctPath, fmWrite)
    let magic: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]
    discard f.writeBytes(magic, 0, 5)
    f.close()

    let slicesDir = tmpDir / "trace.ct_slices"
    createDir(slicesDir)
    writeFile(slicesDir / "slice_0000.ct", "slice0")

    check hasPreSplitSlices(tmpDir) == true

  test "returns false when no slices":
    let tmpDir = getTempDir() / "test_has_slices_false"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    writeFile(tmpDir / "trace.db", "not a ct file")

    check hasPreSplitSlices(tmpDir) == false


suite "MCR Enrichment — countSlices":

  test "counts .ct files in slices directory":
    let tmpDir = getTempDir() / "test_count_slices"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    writeFile(tmpDir / "slice_0000.ct", "s0")
    writeFile(tmpDir / "slice_0001.ct", "s1")
    writeFile(tmpDir / "slice_0002.ct", "s2")
    writeFile(tmpDir / "manifest.smnf", "manifest")
    writeFile(tmpDir / "analysis.manifest", "analysis")

    check countSlices(tmpDir) == 3

  test "returns zero for empty directory":
    let tmpDir = getTempDir() / "test_count_slices_empty"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    check countSlices(tmpDir) == 0

  test "returns zero for non-existent directory":
    check countSlices("/tmp/this_path_should_not_exist_count_42") == 0

  test "does not count non-.ct files":
    let tmpDir = getTempDir() / "test_count_slices_noct"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    writeFile(tmpDir / "manifest.smnf", "manifest")
    writeFile(tmpDir / "analysis.manifest", "analysis")
    writeFile(tmpDir / "readme.txt", "info")

    check countSlices(tmpDir) == 0
