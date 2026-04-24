## Session switching for multi-replay sessions (M11).
##
## Implements the destroy/recreate approach: saves the current GL layout
## config onto the active ``ReplaySession``, tears down the GL instance
## and all Karax component renderers, switches ``activeSessionIndex``,
## then rebuilds the GL from the target session's saved layout config.
##
## This is approach (a) from the design doc — full destroy/recreate.
## Monaco editors and all GL-managed components are recreated from scratch.
##
## To avoid circular imports (layout -> session_tabs -> session_switch ->
## layout), the actual ``initLayout`` call is wired in at runtime via
## ``setInitLayoutProc``.

import
  std/[strformat, jsffi],
  karax,
  ../types,
  ../renderer,
  ../utils,
  ../lib/logging

import kdom except Location

# ---------------------------------------------------------------------------
# Deferred dependency on initLayout (avoids circular import)
# ---------------------------------------------------------------------------

type
  InitLayoutProc = proc(config: GoldenLayoutResolvedConfig) {.nimcall.}

var initLayoutImpl: InitLayoutProc = nil

proc setInitLayoutProc*(p: InitLayoutProc) =
  ## Called once from layout.nim to wire in the real ``initLayout``.
  initLayoutImpl = p

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc saveSessionLayout*(session: ReplaySession, ui: Components) =
  ## Snapshot the current GL resolved config onto the session so it can
  ## be restored later.  No-op when there is no active layout.
  if not ui.layout.isNil:
    try:
      session.savedLayoutConfig = ui.layout.saveLayout()
    except:
      cwarn "session_switch: saveLayout failed: " & getCurrentExceptionMsg()

proc destroyCurrentLayout*(data: Data) =
  ## Tear down the current GoldenLayout instance, reset all component
  ## state, and clear the GL container DOM.  After this call the UI is
  ## a blank slate ready for ``restoreSessionLayout``.
  ##
  ## Delegates to ``renderer.resetLayoutState`` which already handles
  ## destroying the GL instance, resetting ``Components``, and clearing
  ## component mappings.
  resetLayoutState(data)

  # Clear the GL root DOM element so that ``initLayout`` starts with
  # an empty container.  The element id matches what ``initLayout`` uses.
  let root = document.getElementById(cstring"ROOT")
  if not root.isNil:
    root.innerHTML = cstring""

proc restoreSessionLayout*(data: Data) =
  ## Rebuild the GL from the active session's saved layout config (or
  ## its current ``resolvedConfig`` if no snapshot was saved yet).
  ##
  ## This follows the same pattern as the restart flow in ``ui_js.nim``:
  ## set ``resolvedConfig``, call ``createUIComponents``, then init layout.
  let session = data.activeSession
  if not session.savedLayoutConfig.isNil:
    data.ui.resolvedConfig = session.savedLayoutConfig
  # If savedLayoutConfig is nil the session was never switched away from,
  # so resolvedConfig already holds the right layout.

  data.createUIComponents()

  # Replicate the logic of tryInitLayout (defined in ui_js.nim which we
  # cannot import here):  when pageLoaded and initEventReceived are set
  # and there is no current layout, create one from the resolved config.
  if data.ui.pageLoaded and data.ui.initEventReceived:
    if data.ui.layout.isNil and initLayoutImpl != nil:
      initLayoutImpl(data.ui.resolvedConfig)
    redrawAll()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc createNewSession*(data: Data) =
  ## Create a new, empty ReplaySession and switch to it.
  ##
  ## The new session is a blank slate: it has default services, an empty
  ## editor, and inherits the current session's GL layout config so that
  ## the panel arrangement is preserved.  The actual trace loading into
  ## this session is handled separately (e.g. via the trace selector or
  ## IPC).
  ##
  ## This implements the core of M12: clicking "+" in the tab bar creates
  ## a new tab backed by its own ReplaySession.
  let sessionId = data.sessions.len
  var session = newReplaySession(ReplaySessionId(sessionId))
  session.dapApi = DapApi()
  session.viewsApi = setupSinglePageViewsApi(
    cstring("single-page-frontend-to-views-" & $sessionId))
  session.services = Services(
    eventLog: EventLogService(),
    debugger: DebuggerService(
      locals: @[],
      registerState: JsAssoc[cstring, cstring]{},
      breakpointTable: JsAssoc[cstring, JsAssoc[int, UIBreakpoint]]{},
      valueHistory: JsAssoc[cstring, ValueHistory()]{},
      paths: @[],
      skipInternal: true,
      skipNoSource: false,
      historyIndex: 1,
      showInlineValues: true),
    editor: EditorService(
      open: JsAssoc[cstring, TabInfo]{},
      loading: @[],
      completeMoveResponses: JsAssoc[cstring, MoveState]{},
      closedTabs: @[],
      saveHistoryTimeoutId: -1,
      switchTabHistoryLimit: 2000,
      expandedOpen: JsAssoc[cstring, TabInfo]{},
      cachedFiles: JsAssoc[cstring, TabInfo]{},
      addedDiffId: @[],
      changedDiffId: @[],
      deletedDiffId: @[],
      index: 1),
    calltrace: CalltraceService(
      callstackCollapse: (name: cstring"", level: -1),
      callstackLimit: CALLSTACK_DEFAULT_LIMIT,
      calltraceJumps: @[cstring""],
      nonLocalJump: true,
      isCalltrace: true,
      loadingArgs: initJsSet[cstring]()),
    history: HistoryService(),
    flow: FlowService(),
    trace: TraceService(),
    search: SearchService(
      paths: JsAssoc[cstring, bool]{},
      pluginCommands: JsAssoc[cstring, SearchSource]{},
      activeCommandName: cstring"",
      selected: 0),
    shell: ShellService())
  session.ui = Components(
    focusHistory: @[],
    editModeHiddenPanels: @[],
    savedLayoutBeforeEdit: nil,
    editModeLayout: nil,
    lastUsedEditLayout: nil
  )
  session.connection = ConnectionState(
    connected: true,
    reason: ConnectionLossNone,
    detail: cstring""
  )
  session.network = Network(
    futures: JsAssoc[cstring, JsAssoc[cstring, Future[JsObject]]]{})
  session.pointList = PointListData(
    tracepoints: JsAssoc[int, Tracepoint]{})
  session.status = StatusState(
    lastDirection: DebForward,
    currentOperation: cstring"",
    currentHistoryOperation: cstring"",
    finished: false,
    stableBusy: false,
    historyBusy: false,
    traceBusy: false,
    hasStarted: false,
    lastAction: cstring"",
    operationCount: 0,
  )
  session.startOptions = StartOptions(
    loading: false,
    screen: true,
    inTest: false,
    record: false,
    edit: false,
    name: cstring"",
    frontendSocket: SocketAddressInfo(),
    backendSocket: SocketAddressInfo(),
    idleTimeoutMs: 10 * 60 * 1_000)
  session.maxRRTicks = 100_000

  # Inherit the current session's layout config so the new tab has the
  # same panel arrangement.  saveSessionLayout snapshots the live GL
  # state onto the session so it can be restored later.
  let currentSession = data.activeSession
  saveSessionLayout(currentSession, data.ui)
  if not currentSession.savedLayoutConfig.isNil:
    session.savedLayoutConfig = currentSession.savedLayoutConfig
  else:
    # No saved layout yet — snapshot the live resolvedConfig.
    session.savedLayoutConfig = data.ui.resolvedConfig

  data.sessions.add(session)

  clog "session_switch: created new session " & $sessionId &
    " (total: " & $data.sessions.len & ")"

  # Switch to the newly created session.
  switchSession(data, sessionId)

proc switchSession*(data: Data, targetIndex: int) =
  ## Switch from the currently active replay session to ``targetIndex``.
  ##
  ## Does nothing when the target is already active or the index is out
  ## of bounds.  The sequence of operations:
  ##
  ## 1. Save the current session's GL layout snapshot.
  ## 2. Destroy the current GL instance and all component state.
  ## 3. Update ``activeSessionIndex`` (all forwarding templates now
  ##    point to the target session).
  ## 4. Restore the target session's GL layout.
  ## 5. Trigger a full Karax redraw.
  if targetIndex == data.activeSessionIndex:
    return
  if targetIndex < 0 or targetIndex >= data.sessions.len:
    cwarn "session_switch: target index out of bounds: " &
      $targetIndex & " (have " & $data.sessions.len & " sessions)"
    return

  clog "session_switch: switching from session " &
    $data.activeSessionIndex & " to " & $targetIndex

  # 1. Save current layout
  saveSessionLayout(data.activeSession, data.ui)

  # 2. Destroy current GL
  destroyCurrentLayout(data)

  # 3. Switch active session — all Data forwarding templates now resolve
  #    to the target session's fields.
  data.activeSessionIndex = targetIndex

  # 4. Restore target session's layout
  restoreSessionLayout(data)

  # 5. Full redraw so that every Karax component picks up the new
  #    session's data.
  redrawAll()
