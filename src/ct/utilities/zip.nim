import streams, std/[os, osproc]
import zip/zipfiles

proc zipFolder*(source, output: string,
                onProgress: proc(progressPercent: int) = nil,
                storeOnly: bool = false) =
  ## Zip the contents of `source` into the archive at `output`.
  ##
  ## When `storeOnly` is true, files are stored without compression
  ## (ZIP_CM_STORE / ``zip -0``). This is useful for CTFS .ct files that
  ## are already internally compressed — wrapping them in a deflate zip
  ## would waste CPU on redundant compression with negligible size
  ## reduction.
  ##
  ## The store-only path shells out to the ``zip`` command with ``-0``
  ## (store mode) because the Nim zip/zipfiles library does not expose
  ## per-file compression settings.
  if storeOnly:
    # Use the external `zip` command in store mode (-0 = no compression,
    # -r = recurse into directories, -j is NOT used so paths are relative).
    # We cd into `source` so the archive contains relative paths.
    let cmd = "cd " & quoteShell(source) & " && zip -0 -r " & quoteShell(output) & " ."
    let (cmdOutput, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      raise newException(IOError,
        "zip -0 failed (exit " & $exitCode & "): " & cmdOutput)
    if onProgress != nil:
      onProgress(100)
    return

  var zip: ZipArchive

  var totalSize: int64 = 0
  var totalWritten: int64 = 0
  var lastPercentSent = 0
  for file in walkDirRec(source):
    totalSize += getFileSize(file)

  for file in walkDirRec(source):
    totalWritten += getFileSize(file)
    if not zip.open(output, fmReadWrite):
      raise newException(IOError, "Failed to open ZIP: " & source)

    let relPath = file.relativePath(source)
    let fileStream = newFileStream(file, fmRead)
    zip.addFile(relPath, fileStream)
    zip.close()
    fileStream.close()

    if onProgress != nil:
      let percent = int(totalWritten * 100 div totalSize)
      if percent > lastPercentSent:
        onProgress(percent)
        lastPercentSent = percent

proc unzipIntoFolder*(zipPath, targetDir: string) {.raises: [IOError, OSError, Exception].} =
  var zip: ZipArchive
  if not zip.open(zipPath, fmRead):
    raise newException(IOError, "Failed to open ZIP: " & zipPath)

  createDir(targetDir)
  zip.extractAll(targetDir)

  zip.close()
