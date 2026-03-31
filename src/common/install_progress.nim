## Unified progress reporting for the ``ct install`` command.
##
## Provides a single API that emits either human-readable text (default)
## or newline-delimited JSON (``--json`` flag) for machine consumption.
##
## JSON output format (one object per line):
##
## .. code-block:: json
##   {"step":"path","status":"started",
##    "message":"Adding ct to PATH","fatal":false}
##   {"step":"path","status":"completed",
##    "message":"Added ct to PATH","fatal":false}
##   {"step":"bpf","status":"failed",
##    "message":"setcap failed","fatal":false}
##
## The GUI parses these lines to show step-by-step progress. Non-JSON lines
## (from sub-processes like ``bpf_install`` or the Agent Harbor installer)
## are ignored by the GUI parser.

import std/json

type
  InstallStep* = enum
    ## Individual steps in the ``ct install`` process.
    stepPath = "path"
    stepDesktop = "desktop"
    stepBpf = "bpf"
    stepAgentHarbor = "agent-harbor"

  InstallStatus* = enum
    ## Status of an individual install step.
    statusStarted = "started"
    statusCompleted = "completed"
    statusFailed = "failed"
    statusSkipped = "skipped"

  InstallReporter* = ref object
    ## Emits install progress events in either text or JSON mode.
    jsonMode*: bool

proc newInstallReporter*(jsonMode: bool): InstallReporter =
  InstallReporter(jsonMode: jsonMode)

proc report*(
    r: InstallReporter, step: InstallStep,
    status: InstallStatus,
    message: string = "", fatal: bool = false) =
  ## Emit a progress event for the given install step.
  ##
  ## In JSON mode, emits a single-line JSON object to stdout.
  ## In text mode, prints the message (if non-empty) to stdout.
  ## The ``fatal`` field distinguishes hard failures (that abort install)
  ## from non-fatal warnings (that allow install to continue).
  if r.jsonMode:
    let event = %*{
      "step": $step,
      "status": $status,
      "message": message,
      "fatal": fatal,
    }
    echo $event
  else:
    if message.len > 0:
      echo message
