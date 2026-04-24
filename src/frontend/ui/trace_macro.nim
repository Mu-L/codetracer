## Trace Macro Execution (M11)
##
## Provides the "Trace Macro Execution" context menu action for the
## CodeTracer editor.  When triggered on a Nim macro call, this sends
## the ``workspace/executeCommand`` request with ``nim/traceExpandMacro``
## to the Nim language server.  The langserver invokes nimsuggest's
## ``traceExpand`` command which produces a .ct trace file.  The
## resulting trace file path is used to open a new session tab.

import
  std/[asyncjs, jsffi, strformat],
  ui_imports,
  ../[event_helpers, lsp_router],
  session_switch

# JS interop helpers for building the LSP request payload.
proc newJsObj(): JsObject {.importjs: "({})".}
proc jsArr(): JsObject {.importjs: "([])".}
proc jsPush(target: JsObject; value: JsObject) {.importjs: "#.push(#)".}
proc setStr(target: JsObject; name: cstring; value: cstring) {.importjs: "#[#] = #".}
proc setInt(target: JsObject; name: cstring; value: int) {.importjs: "#[#] = #".}
proc setObj(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
proc getField(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
proc toStr(value: JsObject): cstring {.importjs: "String(#)".}
proc jsIsNilOrUndefined(value: JsObject): bool {.importjs: "((function(v){return v == null || v === undefined})(#))".}

proc traceExpandMacro*(data: Data; filePath: cstring; line: int;
                       character: int) {.async.} =
  ## Send ``nim/traceExpandMacro`` via ``workspace/executeCommand`` and
  ## open the resulting .ct trace in a new session tab.
  ##
  ## ``line`` and ``character`` use zero-based LSP coordinates (the
  ## Monaco editor position is 1-based, so the caller must subtract 1
  ## from the line number before calling this proc).
  let nimClient = getActiveClient("nim")
  if nimClient.isNil:
    data.viewsApi.warnMessage(
      cstring"Nim language server is not connected. Cannot trace macro.")
    return

  # Build the workspace/executeCommand request payload.
  # The Nim langserver's executeCommand handler for nim/traceExpandMacro
  # expects a single argument object: {uri, line, character}.
  let arg = newJsObj()
  let uri = cstring("file://" & $filePath)
  arg.setStr("uri", uri)
  arg.setInt("line", line)
  arg.setInt("character", character)

  let args = jsArr()
  args.jsPush(arg)

  let params = newJsObj()
  params.setStr("command", cstring"nim/traceExpandMacro")
  params.setObj("arguments", args)

  data.viewsApi.infoMessage(cstring"Tracing macro expansion...")

  var response: JsObject
  try:
    response = await sendLspRequest("nim",
      cstring"workspace/executeCommand", params)
  except CatchableError as e:
    let msg = e.msg
    if "not a macro" in msg or "No trace result" in msg:
      data.viewsApi.warnMessage(
        cstring"No macro call found at this position.")
    elif "not support" in msg or "traceExpand" in msg:
      data.viewsApi.errorMessage(
        cstring"The Nim language server does not support trace expansion. " &
        cstring"Ensure a trace-enabled nimsuggest is configured.")
    else:
      data.viewsApi.errorMessage(
        cstring("Trace macro failed: " & msg))
    return

  if response.isNil:
    data.viewsApi.errorMessage(
      cstring"Trace macro returned an empty response.")
    return

  let tracePathField = response.getField("tracePath")
  if jsIsNilOrUndefined(tracePathField):
    data.viewsApi.errorMessage(
      cstring"Trace macro response did not contain a trace path.")
    return

  let tracePath = tracePathField.toStr
  if tracePath.len == 0:
    data.viewsApi.errorMessage(
      cstring"Trace macro returned an empty trace path.")
    return

  clog cstring(fmt"trace_macro: received trace path: {tracePath}")

  # Open the .ct file in a new session tab.  The main process handles
  # the actual trace loading -- we send an IPC message with the path
  # and the main process resolves the trace metadata and starts the
  # replay backend.
  createNewSession(data)
  data.ipc.send(cstring"CODETRACER::load-trace-file",
                js{tracePath: tracePath})
