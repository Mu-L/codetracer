import streams, nimcrypto, std/[ terminal, options, strutils, strformat, os, httpclient, uri, net, json ]
import ../../common/[ config, trace_index, paths, lang, types ]
import ../utilities/[ types, zip, language_detection ]
import ../trace/storage_and_import, ../globals
import remote_config, api_client, file_transfer as ft, tenant_resolver

proc parseDownloadUrl(url: string): tuple[orgSlug: string, traceId: string] =
  ## Parses URLs like ``https://web.codetracer.com/org-slug/trace-guid/download``.
  ## Matches the C# ``PageRoutes.Organization.Replay.Download.Deconstruct`` pattern
  ## where the route template is ``/{orgSlug}/{traceGuid}/download``.
  let parsed = parseUri(url)
  let parts = parsed.path.strip(chars = {'/'}).split('/')
  # Expected: [orgSlug, traceGuid, "download"] or [orgSlug, traceGuid]
  if parts.len >= 2:
    let candidateId = parts[^1]
    if candidateId.toLowerAscii() == "download" and parts.len >= 3:
      result.orgSlug = parts[^3]
      result.traceId = parts[^2]
    else:
      # URL without trailing /download
      result.orgSlug = parts[^2]
      result.traceId = parts[^1]
    return
  raise newException(ValueError, "Invalid download URL: " & url)

proc downloadFile(url: string, outputPath: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)): int =
  ## Downloads a trace archive from a CI platform URL.
  ## Uses the native API client instead of shelling out to ct-remote.
  let remoteConf = initRemoteConfig()
  let bearerToken = remoteConf.getBearerToken(token.get(""))
  let resolvedBaseUrl = remoteConf.resolveBaseRemoteUrl(baseUrl.get(""))

  var client = initApiClient(resolvedBaseUrl)
  defer: client.close()

  let (orgSlug, traceId) = parseDownloadUrl(url)
  if traceId.len == 0 or orgSlug.len == 0:
    echo "error: invalid download URL"
    return 1

  # Validate the user has access to this organization's tenant.
  discard resolveTenantId(client, orgSlug, bearerToken)

  let downloadResp = client.requestTraceDownloadUrl(traceId, bearerToken)
  ft.downloadToFile(downloadResp.downloadUrl, outputPath)
  return 0

proc downloadTrace*(url: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)): int =
  let traceId = trace_index.newID(false)

  let downloadTarget = codetracerTmpPath / fmt"downloaded-trace-{traceId}.zip"

  let unzippedLocation = codetracerTraceDir / "trace-" & $traceId

  let downloadExitCode = downloadFile(url, downloadTarget, token, baseUrl)
  if downloadExitCode != 0:
    echo "error: problem: download failed"
    quit(downloadExitCode)

  unzipIntoFolder(downloadTarget, unzippedLocation)
  removeFile(downloadTarget)

  let tracePath = unzippedLocation / "trace.json"
  let traceJson = parseJson(readFile(tracePath))
  let traceMetadataPath = unzippedLocation / "trace_metadata.json"
  let metadataJson = parseJson(readFile(traceMetadataPath))
  let tracePathsMetadata = parseJson(readFile(unzippedLocation / "trace_paths.json"))
  let isWasm = metadataJson{"program"}.getStr("").extractFilename.split(".")[^1] == "wasm" # Check if language is wasm

  var pathValue = ""
  for item in tracePathsMetadata:
    if item.getStr("") != "":
      pathValue = item.getStr("")
      break

  let lang = detectLang(pathValue.extractFilename, LangUnknown, isWasm)
  let recordPid = NO_PID # for now not processing the pid , but it can be
  # accessed from trace metadata file if we need it in the future
  discard importTrace(unzippedLocation, traceId, recordPid, lang, DB_SELF_CONTAINED_DEFAULT, url)
  return traceId

proc downloadTraceCommand*(traceDownloadUrl: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)) =
  try:
    let traceId = downloadTrace(traceDownloadUrl, token, baseUrl)
    if isatty(stdout):
      echo fmt"OK: downloaded with trace id {traceId}"
    else:
      # being parsed by `ct` index code
      echo traceId

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)
