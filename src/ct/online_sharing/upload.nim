import std/[
  terminal, options, strutils, strformat,
  os, httpclient, uri, net, json,
  sequtils, streams, oids
]
import ../../common/[ trace_index, types ]
import ../utilities/[ zip, types, progress_update ]
import ../../common/[ config, paths ]
import ../cli/interactive_replay
import ../codetracerconf
import ../trace/shell
import remote_config, api_client, file_transfer, tenant_resolver
import mcr_enrichment

proc uploadFile(
  traceZipPath: string,
  org: Option[string],
  token: Option[string] = none(string),
  baseUrl: Option[string] = none(string),
): UploadedInfo {.raises: [KeyError, Exception].} =
  ## Uploads a trace zip file to the CI platform using the native API client.
  ## Returns an UploadedInfo with the exit code and file ID.
  result = UploadedInfo(exitCode: 0)
  try:
    let remoteConf = initRemoteConfig()
    let bearerToken = remoteConf.getBearerToken(token.get(""))
    let resolvedBaseUrl = remoteConf.resolveBaseRemoteUrl(baseUrl.get(""))

    var client = initApiClient(resolvedBaseUrl)
    defer: client.close()

    # Resolve the target tenant/organization.
    let defaultOrg = remoteConf.readConfigValue(DefaultOrganizationKey)
    let orgSlug = resolveTenantValueOrSlug(defaultOrg, org.get(""))
    let (tenantId, resolvedSlug) = resolveTenantId(client, orgSlug, bearerToken)

    # Request a presigned upload URL from the server.
    let fileSize = getFileSize(traceZipPath)
    let fileName = extractFilename(traceZipPath)
    let uploadResp = client.requestTraceUploadUrl(
      tenantId, fileName, "application/zip", fileSize, bearerToken)

    # Upload the file to the presigned URL.
    let etag = putFile(uploadResp.uploadUrl, traceZipPath)

    # Confirm the upload with the ETag.
    client.confirmTraceUpload(uploadResp.traceId, etag, bearerToken)

    result.fileId = uploadResp.traceId

    let replayUrl = fmt"{resolvedBaseUrl}/{resolvedSlug}/replay/confirm/{uploadResp.traceId}"
    echo "File uploaded successfully."
    echo "File ID: " & uploadResp.traceId
    echo "You can run the replay in the browser from here:"
    echo "  " & replayUrl

  except CatchableError as e:
    echo "error: uploadFile exception: ", e.msg
    result.exitCode = 1


proc onProgress(ratio, start: int, message: string, lastPercentSent: ref int): proc(progressPercent: int) =
  proc(progressPercent: int) =
    let scaled = start + (progressPercent * ratio) div 100
    if scaled > lastPercentSent[]:
      lastPercentSent[] = scaled
      logUpdate(scaled, message)


proc uploadSplitTrace*(trace: Trace, slicesDir: string,
    org: Option[string],
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)): UploadedInfo =
  ## Upload a pre-split MCR trace by zipping only the slices directory.
  ##
  ## When `ct-mcr record --split` produces individual slice .ct files in a
  ## `_slices/` subdirectory, we zip only that directory instead of the full
  ## outputFolder. This avoids uploading duplicate data (the original full
  ## .ct file) and gives the server pre-split files ready for analysis.
  ##
  ## The zip uses store-only mode (no compression) because CTFS .ct files
  ## are already internally compressed. Re-compressing them with deflate
  ## would waste CPU with negligible size reduction.
  ##
  ## The resulting zip contains:
  ##   slice_0000.ct
  ##   slice_0001.ct
  ##   ...
  ##   analysis.manifest  (if present)
  ##   manifest.smnf      (if present)
  let sliceCount = countSlices(slicesDir)
  echo "Uploading " & $sliceCount & " pre-split slices from: " & slicesDir

  # Create a unique temp directory for the zip file.
  let id = $genOid()
  let traceTempUploadZipFolder = codetracerTmpPath / fmt"trace-upload-zips-{id}"
  createDir(traceTempUploadZipFolder)
  let outputZip = traceTempUploadZipFolder / fmt"tmp.zip"

  let lastPercentSent = new int
  # Use storeOnly=true to avoid double-compressing CTFS files that are
  # already internally compressed.
  zipFolder(slicesDir, outputZip,
    onProgress = onProgress(ratio = 33, start = 0,
      "Zipping slices (store-only, no compression)..", lastPercentSent),
    storeOnly = true)

  var uploadInfo = UploadedInfo()
  try:
    uploadInfo = uploadFile(outputZip, org, token, baseUrl)
  except CatchableError as e:
    echo "uploadSplitTrace error: ", e.msg
    uploadInfo.exitCode = 1
  finally:
    removeFile(outputZip)
    removeDir(traceTempUploadZipFolder)

  return uploadInfo


proc uploadTrace*(trace: Trace, org: Option[string],
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
    noPortable: bool = false,
    noSplitUpload: bool = false): UploadedInfo =
  # Detect and enrich MCR traces before upload. This adds binaries and
  # debug symbols to the .ct container so the trace is self-contained
  # and can be replayed on a different machine (e.g. the CI server).
  let enriched = enrichMcrTraceIfNeeded(trace.outputFolder, noPortable)
  if enriched:
    echo "MCR trace detected: added portable payload (binaries + symbols)"

  # Check for pre-split slices. When ct-mcr record --split is used, the trace
  # output contains a _slices/ directory with individual .ct files. Uploading
  # just the slices directory avoids duplicating data (the full .ct is the
  # concatenation of all slices) and gives the server pre-split files.
  if not noSplitUpload:
    let slicesDir = findSlicesDir(trace.outputFolder)
    if slicesDir.len > 0:
      let sliceCount = countSlices(slicesDir)
      if sliceCount > 0:
        echo "MCR trace with pre-split slices detected"
        let uploadInfo = uploadSplitTrace(
          trace, slicesDir, org, token, baseUrl)
        quit(uploadInfo.exitCode)

  # Full upload: zip the entire outputFolder and upload as one file.
  # try to generate a unique path, so even if we don't remove it/clean it up
  #   it's not easy to clash with it on a next upload
  # https://nim-lang.org/docs/oids.html
  let id = $genOid()
  let traceTempUploadZipFolder = codetracerTmpPath / fmt"trace-upload-zips-{id}"
  createDir(traceTempUploadZipFolder)
  # alexander: import to be tmp.zip for the codetracer-ci service iirc
  let outputZip = traceTempUploadZipFolder / fmt"tmp.zip"

  let lastPercentSent = new int
  zipFolder(trace.outputFolder, outputZip, onProgress = onProgress(ratio = 33, start = 0, "Zipping files..", lastPercentSent))
  var uploadInfo = UploadedInfo()
  try:
    uploadInfo = uploadFile(outputZip, org, token, baseUrl)
  except CatchableError as e:
    echo "uploadTrace error: ", e.msg
    uploadInfo.exitCode = 1
  finally:
    removeFile(outputZip)
    # TODO: if we start to support directly passed zips: as an argument or because
    #   of multitraces, don't remove such a folder for those cases
    # this one is just a temp one:
    removeDir(traceTempUploadZipFolder)

  quit(uploadInfo.exitCode)

  # TODO: result = uploadInfo?

proc uploadCommand*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool,
  uploadOrg: Option[string],
  uploadToken: Option[string] = none(string),
  uploadBaseUrl: Option[string] = none(string),
  noPortable: bool = false,
  noSplitUpload: bool = false,
) =
  let config: Config = loadConfig(folder=getCurrentDir(), inTest=false)

  if not config.traceSharing.enabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  var uploadInfo: UploadedInfo
  var trace: Trace

  if interactive:
    trace = interactiveTraceSelectMenu(StartupCommand.upload)
  else:
    trace = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)

  if trace.isNil:
    echo "ERROR: can't find trace in local database"
    quit(1)

  try:
    uploadInfo = uploadTrace(trace, uploadOrg, uploadToken, uploadBaseUrl,
      noPortable, noSplitUpload)
  except CatchableError as e:
    echo e.msg
    quit(1)

  if isatty(stdout):
    echo "\n"
    echo fmt"""
      OK: uploaded, you can share the link.
      NB: It's sensitive: everyone with this link can access your trace!

      Download with:
      `ct download {uploadInfo.downloadKey}`
      """
  else:
    echo fmt"""{{"downloadKey": "{uploadInfo.downloadKey}", "controlId": "{uploadInfo.controlId}", "storedUntilEpochSeconds": {uploadInfo.storedUntilEpochSeconds}}}"""

  quit(0)
