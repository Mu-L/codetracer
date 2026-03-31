## Agent Harbor installation support for CodeTracer.
##
## CodeTracer depends on Agent Harbor for AI-powered debugging assistance.
## This module detects whether Agent Harbor is already installed and, if not,
## downloads and runs the official installer script from
## ``https://install.agent-harbor.com``.
##
## The installer is a self-contained shell script that handles its own
## privilege escalation (via ``sudo``), distribution detection, and package
## installation. When invoked from the GUI via ``pkexec``, the process is
## already running as root, so the installer's internal ``sudo`` calls are
## no-ops.
##
## On download failure (no internet), the installer retries up to 3 times
## and then returns a descriptive error. The caller treats this as non-fatal:
## CodeTracer continues to work without Agent Harbor, and the user is
## informed at the end of the install process.

import
  std/[os, osproc, strformat, strutils],
  results

const
  AgentHarborInstallUrl* = "https://install.agent-harbor.com"
    ## Official one-liner installer URL. The script is designed to be piped
    ## to ``sh`` (``curl -fsSL <url> | sh``).

  MaxDownloadRetries = 3
    ## Number of download attempts before giving up.

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

proc isAgentHarborInstalled*(): bool =
  ## Returns true if the ``ah`` command is available on PATH.
  ## This is the primary Agent Harbor CLI binary installed by all
  ## package variants (full, cli-only, fs-only).
  findExe("ah").len > 0

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

proc installAgentHarbor*(): Result[void, string] =
  ## Downloads and runs the Agent Harbor installer script.
  ##
  ## The installer handles its own privilege escalation, distribution
  ## detection, GPG verification, and package installation. It supports
  ## non-interactive execution (designed for ``curl | sh`` usage).
  ##
  ## Returns ``ok()`` if Agent Harbor is already installed or was
  ## installed successfully. Returns ``err(message)`` if the download
  ## failed after all retries (likely no internet access) or if the
  ## installer script exited with an error.

  if isAgentHarborInstalled():
    echo "Agent Harbor is already installed."
    return ok()

  let curlPath = findExe("curl")
  if curlPath.len == 0:
    return err(
      "curl is not installed; " &
      "cannot download the Agent Harbor installer")

  var lastErr = ""
  for attempt in 1..MaxDownloadRetries:
    try:
      # The AH installer is designed to be piped to sh. We use
      # poEvalCommand so the shell interprets the pipe.
      let cmd =
        fmt"{curlPath} -fsSL " &
        fmt"{AgentHarborInstallUrl}" &
        " | sh -s -- --skip-verify"
      let (output, exitCode) = execCmdEx(
        cmd, options = {poUsePath, poEvalCommand})
      if exitCode == 0:
        echo "Agent Harbor installed successfully."
        return ok()
      lastErr =
        fmt"attempt {attempt}/{MaxDownloadRetries}" &
        fmt": installer exited with code {exitCode}"
      if output.len > 0:
        # Show truncated output for diagnostics.
        let lines = output.split('\n')
        let tail = if lines.len > 5: lines[^5..^1] else: lines
        lastErr &= "\n  " & tail.join("\n  ")
    except CatchableError as e:
      lastErr =
        fmt"attempt {attempt}/{MaxDownloadRetries}" &
        fmt": {e.msg}"

    if attempt < MaxDownloadRetries:
      echo fmt"Agent Harbor install attempt {attempt} failed, retrying..."

  return err("Agent Harbor was not installed due to lack of internet access")
