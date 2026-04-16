## REST API client for the CodeTracer CI platform.
##
## Replaces the C# ``MonolithApiClient``. All calls target the ``/api/v1/``
## endpoint group. Authentication is via bearer token in the Authorization header.
##
## Endpoint reference (from MonolithApiClient.cs):
## - ``GET  tenants``                                        → list user's tenants
## - ``POST tenants/{tenantId}/traces/upload-url``           → presigned upload URL
## - ``POST traces/{traceId}/confirm-upload``                → confirm upload with etag
## - ``GET  traces/{traceId}/download-url``                  → presigned download URL
## - ``GET  billing/license``                                → license info (v2)
## - ``POST license/issue``                                  → signed CTL license blob
## - ``POST tenants/{tenantId}/traces/upload-session`` (M18a) → create upload session
## - ``POST traces/{sessionId}/slice-upload-url``      (M18a) → presigned slice URL
## - ``POST traces/{sessionId}/finalize``              (M18a) → finalize upload session

import std/[httpclient, json, net, strformat, strutils, uri]

type
  TenantListItem* = object
    tenantId*: string
    displayName*: string
    slug*: string
    role*: string

  TraceUploadUrlResponse* = object
    traceId*: string
    uploadUrl*: string
    expiresAt*: string

  TraceDownloadUrlResponse* = object
    downloadUrl*: string
    expiresAt*: string

  LicenseInfoResponse* = object
    licenseInfo*: string

  UploadSessionResponse* = object
    ## Response from ``POST /tenants/{tenantId}/traces/upload-session``.
    sessionId*: string
    s3KeyPrefix*: string

  SliceUploadUrlResponse* = object
    ## Response from ``POST /traces/{sessionId}/slice-upload-url``.
    uploadUrl*: string
    sliceIndex*: int

  ApiError* = object of CatchableError
    ## Raised when the server returns a non-success HTTP status.

  ApiClient* = object
    baseApiUrl*: string   ## e.g. "https://web.codetracer.com/api/v1/"
    httpClient*: HttpClient

proc initApiClient*(baseRemoteAddress: string): ApiClient =
  ## Creates an API client pointing at ``baseRemoteAddress``.
  ## The ``/api/v1/`` suffix is appended automatically.
  let baseUrl = baseRemoteAddress.strip(chars = {'/'})
  result.baseApiUrl = baseUrl & "/api/v1/"
  result.httpClient = newHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer))

proc close*(client: var ApiClient) =
  client.httpClient.close()

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc bearerHeaders(bearerToken: string): HttpHeaders =
  newHttpHeaders({
    "Authorization": "Bearer " & bearerToken,
    "Content-Type": "application/json",
  })

proc ensureSuccess(response: Response, context: string) =
  ## Raises ``ApiError`` if the response status is not 2xx.
  ## Matches the C# ``EnsureSuccessAsync`` pattern.
  let code = response.code.int
  if code < 200 or code >= 300:
    let body = response.body
    raise newException(ApiError,
      fmt"Remote service returned error: {response.status}" &
      (if body.len > 0: " — " & body else: "") &
      " (during " & context & ")")

# ---------------------------------------------------------------------------
# Tenant endpoints
# ---------------------------------------------------------------------------

proc getTenants*(client: ApiClient, bearerToken: string): seq[TenantListItem] =
  ## ``GET /api/v1/tenants`` → list of tenants the user belongs to.
  let url = client.baseApiUrl & "tenants"
  let response = client.httpClient.request(
    url, httpMethod = HttpGet, headers = bearerHeaders(bearerToken))
  ensureSuccess(response, "getTenants")

  let jsonBody = parseJson(response.body)
  let tenantsArray = jsonBody["tenants"]
  result = @[]
  for item in tenantsArray:
    result.add(TenantListItem(
      tenantId: item["tenantId"].getStr(),
      displayName: item["displayName"].getStr(),
      slug: item["slug"].getStr(),
      role: item["role"].getStr(),
    ))

# ---------------------------------------------------------------------------
# Trace upload endpoints
# ---------------------------------------------------------------------------

proc requestTraceUploadUrl*(client: ApiClient, tenantId: string,
    fileName: string, contentType: string, contentLength: int64,
    bearerToken: string): TraceUploadUrlResponse =
  ## ``POST /api/v1/tenants/{tenantId}/traces/upload-url``
  ## Returns a presigned S3 upload URL.
  let url = client.baseApiUrl & fmt"tenants/{tenantId}/traces/upload-url"
  let body = $ %*{
    "fileName": fileName,
    "contentType": contentType,
    "contentLength": contentLength,
  }
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "requestTraceUploadUrl")

  let jsonBody = parseJson(response.body)
  result = TraceUploadUrlResponse(
    traceId: jsonBody["traceId"].getStr(),
    uploadUrl: jsonBody["uploadUrl"].getStr(),
    expiresAt: jsonBody["expiresAt"].getStr(),
  )

proc confirmTraceUpload*(client: ApiClient, traceId: string, etag: string,
    bearerToken: string) =
  ## ``POST /api/v1/traces/{traceId}/confirm-upload``
  ## Confirms that the file was uploaded successfully with the given ETag.
  let url = client.baseApiUrl & fmt"traces/{traceId}/confirm-upload"
  let body = $ %*{"etag": etag}
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "confirmTraceUpload")

# ---------------------------------------------------------------------------
# Trace download endpoints
# ---------------------------------------------------------------------------

proc requestTraceDownloadUrl*(client: ApiClient, traceId: string,
    bearerToken: string): TraceDownloadUrlResponse =
  ## ``GET /api/v1/traces/{traceId}/download-url``
  ## Returns a presigned S3 download URL.
  let url = client.baseApiUrl & fmt"traces/{traceId}/download-url"
  let response = client.httpClient.request(
    url, httpMethod = HttpGet, headers = bearerHeaders(bearerToken))
  ensureSuccess(response, "requestTraceDownloadUrl")

  let jsonBody = parseJson(response.body)
  result = TraceDownloadUrlResponse(
    downloadUrl: jsonBody["downloadUrl"].getStr(),
    expiresAt: jsonBody["expiresAt"].getStr(),
  )

# ---------------------------------------------------------------------------
# License endpoints
# ---------------------------------------------------------------------------

proc getLicenseInfo*(client: ApiClient,
    bearerToken: string): LicenseInfoResponse =
  ## ``GET /api/v1/billing/license`` → license tier info.
  ## Falls back to the legacy ``POST /api/trace-storage/get-user-license-info``
  ## endpoint if the modern one returns 404 or 405, matching the C#
  ## ``GetLicenseInfoAsync`` implementation.
  let url = client.baseApiUrl & "billing/license"
  let response = client.httpClient.request(
    url, httpMethod = HttpGet, headers = bearerHeaders(bearerToken))

  let code = response.code.int
  if code == 404 or code == 405:
    # Legacy fallback: POST to a different path with token in the body.
    # The legacy endpoint is NOT under /api/v1/ — it's at /api/trace-storage/.
    let baseUrl = client.baseApiUrl.replace("/api/v1/", "/")
    let legacyUrl = baseUrl & "api/trace-storage/get-user-license-info"
    let legacyBody = $ %*{"bearerToken": bearerToken}
    let legacyResponse = client.httpClient.request(
      legacyUrl, httpMethod = HttpPost,
      headers = bearerHeaders(bearerToken), body = legacyBody)
    ensureSuccess(legacyResponse, "getLicenseInfo (legacy)")
    let jsonBody = parseJson(legacyResponse.body)
    return LicenseInfoResponse(licenseInfo: jsonBody["licenseInfo"].getStr())

  ensureSuccess(response, "getLicenseInfo")
  let jsonBody = parseJson(response.body)
  result = LicenseInfoResponse(licenseInfo: jsonBody["licenseInfo"].getStr())

proc issueLicense*(client: ApiClient, bearerToken: string): string =
  ## ``POST /api/v1/license/issue`` → raw binary CTL license blob.
  ## Returns the response body as a raw string (binary data).
  ## The caller should validate the CTL format (magic bytes, minimum size).
  let url = client.baseApiUrl & "license/issue"
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken))
  ensureSuccess(response, "issueLicense")
  result = response.body

# ---------------------------------------------------------------------------
# Upload-session endpoints (M18a per-slice upload)
# ---------------------------------------------------------------------------

proc requestUploadSession*(client: ApiClient, tenantId: string,
    platform: string, recordingMode: string,
    bearerToken: string): UploadSessionResponse =
  ## ``POST /api/v1/tenants/{tenantId}/traces/upload-session``
  ## Creates a new upload session for per-slice streaming upload.
  ## Returns a session ID and S3 key prefix for the upload.
  let url = client.baseApiUrl & fmt"tenants/{tenantId}/traces/upload-session"
  let body = $ %*{
    "platform": platform,
    "recordingMode": recordingMode,
  }
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "requestUploadSession")

  let jsonBody = parseJson(response.body)
  result = UploadSessionResponse(
    sessionId: jsonBody["sessionId"].getStr(),
    s3KeyPrefix: jsonBody["s3KeyPrefix"].getStr(),
  )

proc requestSliceUploadUrl*(client: ApiClient, sessionId: string,
    sliceIndex: int, fileName: string, contentLength: int64,
    bearerToken: string): SliceUploadUrlResponse =
  ## ``POST /api/v1/traces/{sessionId}/slice-upload-url``
  ## Requests a presigned S3 URL for uploading a single slice file.
  let url = client.baseApiUrl & fmt"traces/{sessionId}/slice-upload-url"
  let body = $ %*{
    "sliceIndex": sliceIndex,
    "fileName": fileName,
    "contentLength": contentLength,
  }
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "requestSliceUploadUrl")

  let jsonBody = parseJson(response.body)
  result = SliceUploadUrlResponse(
    uploadUrl: jsonBody["uploadUrl"].getStr(),
    sliceIndex: jsonBody["sliceIndex"].getInt(),
  )

proc finalizeUploadSession*(client: ApiClient, sessionId: string,
    totalSlices: int, totalEvents: int, platform: string,
    bearerToken: string) =
  ## ``POST /api/v1/traces/{sessionId}/finalize``
  ## Marks the upload session as complete after all slices have been uploaded.
  ## The server will process the uploaded slices and make the trace available.
  let url = client.baseApiUrl & fmt"traces/{sessionId}/finalize"
  let body = $ %*{
    "totalSlices": totalSlices,
    "totalEvents": totalEvents,
    "platform": platform,
  }
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "finalizeUploadSession")
