## Remote sharing commands.
##
## Previously this module was a thin wrapper that shelled out to the external
## ``ct-remote`` binary. Now the functionality is implemented natively in Nim.
## The ``runCtRemote`` proc is kept for the deprecated ``ct remote`` passthrough.

import
  std/[ os, osproc, options, sequtils, strutils ],
  ../../common/[ paths ],
  ../cli/[ logging ],
  remote_config, authenticate as auth_module

proc runCtRemote*(args: seq[string]): int {.deprecated: "Use native commands instead".} =
  ## Deprecated: shells out to the external ct-remote binary.
  ## Kept only for the ``ct remote <args>`` escape hatch.
  var execPath = ctRemoteExe
  if not fileExists(execPath):
    execPath = findExe("ct-remote")

  if execPath.len == 0 or not fileExists(execPath):
    echo "ct-remote is no longer required. Use native commands instead:"
    echo "  ct upload, ct download, ct login, ct set-default-org,"
    echo "  ct get-default-org, ct activate, ct check-license"
    return 1

  try:
    let fullArgs = args.concat(@["--binary-name", "ct remote"])
    var options = {poParentStreams}
    if getEnv("CODETRACER_DEBUG_CT_REMOTE", "0") == "1":
      options.incl(poEchoCmd)
    let process = startProcess(execPath, args = fullArgs, options = options)
    result = waitForExit(process)
  except CatchableError as err:
    echo "Failed to launch ct-remote (" & execPath & "): " & err.msg
    result = 1

proc loginCommand*(defaultOrg: Option[string], baseUrl: Option[string] = none(string)) =
  ## Authenticate via browser OAuth flow, optionally set default org.
  let remoteConfig = initRemoteConfig()
  let resolvedBaseUrl = remoteConfig.resolveBaseRemoteUrl(
    baseUrl.get(""))
  try:
    auth_module.authenticate(remoteConfig, resolvedBaseUrl)
  except CatchableError as e:
    echo "Login failed: " & e.msg
    quit(1)
  if defaultOrg.isSome:
    remoteConfig.saveConfigValue(DefaultOrganizationKey, defaultOrg.get)
    echo "Default organization set to: " & defaultOrg.get

proc setDefaultOrg*(newOrg: string) =
  ## Set the default organization in the remote config file.
  let remoteConfig = initRemoteConfig()
  remoteConfig.saveConfigValue(DefaultOrganizationKey, newOrg)
  echo "Default organization set to: " & newOrg

proc getDefaultOrg*() =
  ## Print the current default organization from the remote config file.
  let remoteConfig = initRemoteConfig()
  let org = remoteConfig.readConfigValue(DefaultOrganizationKey)
  if org.len == 0:
    echo "No default organization set. Use 'ct set-default-org <name>' to set one."
  else:
    echo org
