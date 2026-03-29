## CI-specific API methods for the CodeTracer Monolith backend.
##
## Wraps the existing ``ApiClient`` from ``api_client.nim`` with
## higher-level procedures that target the ``/api/v1/ci/`` endpoint group.
## Authentication uses a CI API token (``ci:write`` scope) passed via the
## ``Authorization: Bearer <token>`` header.
##
## Endpoint reference (from the Monolith CI controller):
## - POST ``/api/v1/ci/runs``                    -- create a new run
## - POST ``/api/v1/ci/runs/{runId}/start``      -- mark run as Running
## - POST ``/api/v1/ci/runs/{runId}/complete``    -- mark run as Completed
## - POST ``/api/v1/ci/runs/{runId}/cancel``      -- mark run as Cancelled
## - POST ``/api/v1/ci/runs/{runId}/logs``        -- append a log chunk
## - GET  ``/api/v1/ci/runs/{runId}``            -- get run details/status
## - POST ``/api/v1/ci/runs/{runId}/traces``      -- upload trace metadata

import std/[httpclient, json, net, strformat, os, times]
import ../online_sharing/api_client

type
  CreateRunRequest* = object
    ## Payload for POST /api/v1/ci/runs.
    repositoryUrl*: string
    commitSha*: string
    branchName*: string
    baseCommitSha*: string
    label*: string
    processMonitoring*: bool

  CreateRunResponse* = object
    ## Response from POST /api/v1/ci/runs.
    id*: string
    tenantId*: string
    sequenceNumber*: int

  CIRunStatus* = object
    ## Response from GET /api/v1/ci/runs/{runId}.
    id*: string
    status*: string
    label*: string
    repositoryUrl*: string
    commitSha*: string
    branchName*: string
    createdAt*: string

  LogLine* = object
    ## A single log line for the log-append endpoint.
    timestamp*: string
    stream*: string
    text*: string

  CIApiError* = object of CatchableError
    ## Raised when a CI API call fails after all retries.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

const
  MaxRetries = 3
  InitialBackoffMs = 1000
  MaxBackoffMs = 30_000

proc ciHeaders(token: string): HttpHeaders =
  newHttpHeaders({
    "Authorization": "Bearer " & token,
    "Content-Type": "application/json",
  })

proc ensureCISuccess(response: Response, context: string) =
  ## Raises ``CIApiError`` if the response status is not 2xx.
  let code = response.code.int
  if code < 200 or code >= 300:
    let body = response.body
    raise newException(CIApiError,
      fmt"CI API error: {response.status}" &
      (if body.len > 0: " -- " & body else: "") &
      " (during " & context & ")")

template withRetry(retryContext: string, body: untyped) =
  ## Executes ``body`` with exponential backoff retries on network failure.
  ## CIApiError (non-2xx responses) are NOT retried since they indicate
  ## a problem with the request itself.
  var backoffMs = InitialBackoffMs
  for attempt in 0 .. MaxRetries:
    try:
      body
      break
    except CIApiError:
      raise
    except CatchableError as e:
      if attempt == MaxRetries:
        raise newException(CIApiError,
          "CI API call failed after " & $(MaxRetries + 1) &
          " attempts (" & retryContext & "): " & e.msg)
      let sleepMs = min(backoffMs, MaxBackoffMs)
      sleep(sleepMs)
      backoffMs = backoffMs * 2

# ---------------------------------------------------------------------------
# CI Run lifecycle
# ---------------------------------------------------------------------------

proc createRun*(client: ApiClient, token: string,
                req: CreateRunRequest): CreateRunResponse =
  ## POST /api/v1/ci/runs -- create a new CI run.
  withRetry("createRun"):
    let url = client.baseApiUrl & "ci/runs"
    let reqBody = $ %*{
      "repositoryUrl": req.repositoryUrl,
      "commitSha": req.commitSha,
      "branchName": req.branchName,
      "baseCommitSha": req.baseCommitSha,
      "label": req.label,
      "processMonitoring": req.processMonitoring,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "createRun")
    let j = parseJson(response.body)
    result = CreateRunResponse(
      id: j["id"].getStr(),
      tenantId: j["tenantId"].getStr(),
      sequenceNumber: j{"sequenceNumber"}.getInt(0),
    )

proc startRun*(client: ApiClient, token: string, runId: string) =
  ## POST /api/v1/ci/runs/{runId}/start -- transition run to Running.
  withRetry("startRun"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/start"
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = "{}")
    ensureCISuccess(response, "startRun")

proc completeRun*(client: ApiClient, token: string, runId: string,
                  status: string, exitCode: int,
                  durationSeconds: float) =
  ## POST /api/v1/ci/runs/{runId}/complete -- mark run as completed.
  withRetry("completeRun"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/complete"
    let reqBody = $ %*{
      "status": status,
      "exitCode": exitCode,
      "durationSeconds": durationSeconds,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "completeRun")

proc cancelRun*(client: ApiClient, token: string, runId: string) =
  ## POST /api/v1/ci/runs/{runId}/cancel -- request run cancellation.
  withRetry("cancelRun"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/cancel"
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = "{}")
    ensureCISuccess(response, "cancelRun")

proc appendLogs*(client: ApiClient, token: string, runId: string,
                 lines: seq[LogLine], sequence: int,
                 isFinal: bool) =
  ## POST /api/v1/ci/runs/{runId}/logs -- append a chunk of log lines.
  withRetry("appendLogs"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/logs"
    var jsonLines = newJArray()
    for line in lines:
      jsonLines.add(%*{
        "timestamp": line.timestamp,
        "stream": line.stream,
        "text": line.text,
      })
    let reqBody = $ %*{
      "lines": jsonLines,
      "sequence": sequence,
      "isFinal": isFinal,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "appendLogs")

proc getRunStatus*(client: ApiClient, token: string,
                   runId: string): CIRunStatus =
  ## GET /api/v1/ci/runs/{runId} -- retrieve run details.
  withRetry("getRunStatus"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}"
    let response = client.httpClient.request(
      url, httpMethod = HttpGet, headers = ciHeaders(token))
    ensureCISuccess(response, "getRunStatus")
    let j = parseJson(response.body)
    result = CIRunStatus(
      id: j["id"].getStr(),
      status: j["status"].getStr(),
      label: j{"label"}.getStr(""),
      repositoryUrl: j{"repositoryUrl"}.getStr(""),
      commitSha: j{"commitSha"}.getStr(""),
      branchName: j{"branchName"}.getStr(""),
      createdAt: j{"createdAt"}.getStr(""),
    )

proc uploadTraceMetadata*(client: ApiClient, token: string, runId: string,
                          fileName: string, sizeBytes: int64, s3Key: string,
                          contentHash: string,
                          pid: int = 0): string =
  ## POST /api/v1/ci/runs/{runId}/traces -- register trace metadata.
  ## Returns the trace ID assigned by the server.
  withRetry("uploadTraceMetadata"):
    let url = client.baseApiUrl & fmt"ci/runs/{runId}/traces"
    let reqBody = $ %*{
      "fileName": fileName,
      "sizeBytes": sizeBytes,
      "s3Key": s3Key,
      "contentHash": contentHash,
      "pid": pid,
    }
    let response = client.httpClient.request(
      url, httpMethod = HttpPost, headers = ciHeaders(token), body = reqBody)
    ensureCISuccess(response, "uploadTraceMetadata")
    let j = parseJson(response.body)
    result = j["traceId"].getStr()
