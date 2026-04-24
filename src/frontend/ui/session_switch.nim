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
  std/[strformat, jsffi, asyncjs],
  karax,
  ../types,
  ../dap,
  ../renderer,
  ../utils,
  ../lib/[logging, jslib]

import kdom except Location

# ---------------------------------------------------------------------------
# Deferred dependency on initLayout (avoids circular import)
# ---------------------------------------------------------------------------

type
  InitLayoutProc = proc(config: GoldenLayoutResolvedConfig) {.nimcall.}
  EnsureTabBarRendererProc = proc() {.nimcall.}

var initLayoutImpl: InitLayoutProc = nil
var ensureTabBarRendererImpl: EnsureTabBarRendererProc = nil

proc setInitLayoutProc*(p: InitLayoutProc) =
  ## Called once from layout.nim to wire in the real ``initLayout``.
  initLayoutImpl = p

proc setEnsureTabBarRendererProc*(p: EnsureTabBarRendererProc) =
  ## Called once from layout.nim to wire in the tab-bar renderer setup.
  ## This allows ``restoreSessionLayout`` to ensure the session-tab-bar
  ## Karax renderer exists even when ``initLayout`` is not called.
  ensureTabBarRendererImpl = p

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc saveSessionLayout*(session: ReplaySession, ui: Components) =
  ## Snapshot the current GL layout config onto the session so it can
  ## be restored later.  No-op when there is no active layout.
  ##
  ## IMPORTANT: We save the UNRESOLVED config (via ``fromResolved``), not
  ## the resolved config from ``saveLayout()``.  GoldenLayout's
  ## ``loadLayout()`` expects unresolved configs with string-typed size
  ## values (e.g. "50%").  The resolved config from ``saveLayout()`` has
  ## numeric sizes that cause ``loadLayout`` to crash with
  ## "value.trimStart is not a function".
  if not ui.layout.isNil and not ui.layoutConfig.isNil:
    try:
      let resolved = ui.layout.saveLayout()
      session.savedLayoutConfig = cast[GoldenLayoutResolvedConfig](
        ui.layoutConfig.fromResolved(resolved))
    except:
      cwarn "session_switch: saveLayout failed: " & getCurrentExceptionMsg()

proc resetRootDom() =
  ## Clear ``#ROOT`` and restore the inner structure that ``initLayout``
  ## expects.  GoldenLayout takes over ``#ROOT`` as its container, but
  ## ``initLayout`` also sets up Karax renderers for ``#fixed-search``
  ## (and the ``#context-menu-container`` / ``#main`` are referenced
  ## elsewhere).  After clearing we must recreate these child elements
  ## so the next ``initLayout`` call finds them.
  let root = document.getElementById(cstring"ROOT")
  if root.isNil:
    return
  root.innerHTML = cstring(
    "<div id=\"context-menu-container\" style=\"display: none;\"></div>" &
    "<div id=\"fixed-search\"></div>" &
    "<section id=\"main\"></section>")

proc destroyCurrentLayout*(data: Data) =
  ## Tear down the current GoldenLayout instance, reset all component
  ## state, and clear the GL container DOM.  After this call the UI is
  ## a blank slate ready for ``restoreSessionLayout``.
  ##
  ## When the current session has no layout (e.g. a freshly created empty
  ## session), we skip the full ``resetLayoutState`` — there is no GL
  ## instance to destroy and no component state to reset.  We still clear
  ## the DOM container so the next ``initLayout`` starts with a clean slate.
  if data.ui.layout.isNil:
    # No layout to destroy — just reset the DOM container.
    resetRootDom()
    return

  ## Delegates to ``renderer.resetLayoutState`` which already handles
  ## destroying the GL instance, resetting ``Components``, and clearing
  ## component mappings.
  resetLayoutState(data)

  # Clear and restore the GL root DOM element so that ``initLayout``
  # starts with the expected inner structure.
  #
  # IMPORTANT: We clear ``#ROOT`` (the GoldenLayout container), NOT its
  # parent ``#root-container``.  The ``#session-tab-bar`` element lives
  # OUTSIDE ``#ROOT`` in ``index.html`` specifically so that this
  # clearing operation does not destroy the tab bar DOM.  If the tab bar
  # were inside ``#ROOT``, every session switch would destroy it and
  # Karax's renderer (attached by ``setRenderer``) would lose its target
  # element, breaking tab clicks.
  resetRootDom()

proc callInitLayoutUnchecked(config: GoldenLayoutResolvedConfig) =
  ## Thin wrapper that calls ``initLayoutImpl`` as a normal Nim call.
  ## Exists so that ``callInitLayoutSafe`` can reference the call site
  ## inside a JS-level try/catch without emit-level variable resolution
  ## issues.
  initLayoutImpl(config)

proc callInitLayoutSafe(config: GoldenLayoutResolvedConfig): bool =
  ## Call initLayoutImpl wrapped in a JS-level try/catch to handle both
  ## Nim exceptions and native JS errors (e.g. from GoldenLayout).
  ## Returns true on success, false if an error was caught.
  if initLayoutImpl.isNil:
    return false
  # We use raw JS emit because Nim's ``except Exception:`` does not catch
  # native JS errors (TypeError, RangeError, etc.) — only Nim-derived
  # Exception objects.  The ``initLayout`` proc can throw native JS errors
  # from GoldenLayout's ``loadLayout`` call.
  {.emit: """
    try {
      `callInitLayoutUnchecked`(`config`);
      `result` = true;
    } catch (e) {
      console.warn("session_switch: initLayout failed:", e?.message || String(e));
      `result` = false;
    }
  """.}

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
  #
  # We only call initLayout for sessions that have an actual trace loaded.
  # Empty sessions (no trace, created by the "+" button) don't need a GL
  # layout.  Calling initLayout with a saved config from another session
  # can fail because GoldenLayout's loadLayout expects string-typed size
  # values but saveLayout may emit numeric ones.  More importantly,
  # calling initLayout replaces Karax's event-delegation renderers (via
  # ``setRenderer``), and if ``loadLayout`` then crashes, the new renderer
  # is in a corrupt state and tab clicks stop working.
  if data.ui.pageLoaded and data.ui.initEventReceived:
    if data.ui.layout.isNil and not session.trace.isNil:
      let ok = callInitLayoutSafe(data.ui.resolvedConfig)
      if not ok:
        cwarn "restoreSessionLayout: initLayout failed — layout not created"
    elif data.ui.layout.isNil:
      # Re-create the session-tab-bar Karax renderer so that tab clicks
      # continue to work.  Without this, the old renderer from the
      # destroyed layout's ``initLayout`` call may have stale event
      # delegation state.  We use ``redrawSync`` to ensure the new DOM
      # (with fresh event handlers) is written immediately — the normal
      # ``redraw`` uses ``requestAnimationFrame`` which defers rendering,
      # but we need the handlers active before any click can occur.
      if not ensureTabBarRendererImpl.isNil:
        ensureTabBarRendererImpl()
        if kxiMap.hasKey(cstring"session-tab-bar"):
          redrawSync(kxiMap[cstring"session-tab-bar"])
    else:
      discard  # Layout already exists
  else:
    discard  # Conditions not met (page not loaded or init event not received)

  # Always trigger a full redraw — even when initLayout was skipped (e.g.
  # for empty sessions), the session tab bar and other components outside
  # GL still need to reflect the new session state.
  redrawAll()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc switchSession*(data: Data, targetIndex: int)
  ## Forward declaration — defined below, called by createNewSession.

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
    editors: JsAssoc[cstring, EditorViewComponent]{},
    idMap: JsAssoc[cstring, int]{value: 0, chart: 0},
    layoutSizes: LayoutSizes(startSize: true),
    monacoEditors: @[],
    traceMonacoEditors: @[],
    focusHistory: @[],
    editModeHiddenPanels: @[],
    savedLayoutBeforeEdit: nil,
    editModeLayout: nil,
    lastUsedEditLayout: nil
  )
  # Initialize component mapping arrays — required by ``createUIComponents``
  # and ``generateId`` which access ``componentMapping[content]`` and expect
  # initialised JsAssoc objects, not nil/undefined.  Without this, the
  # first ``registerComponent`` call on the new session crashes with a
  # null-reference error.
  for content in Content:
    session.ui.componentMapping[content] = JsAssoc[int, Component]{}
    session.ui.openComponentIds[content] = @[]

  # Inherit page-readiness flags from the current session so that
  # restoreSessionLayout's condition for calling initLayout is met.
  # Without these, initLayoutImpl is never called for the new session
  # because the condition ``data.ui.pageLoaded and data.ui.initEventReceived``
  # evaluates to false.
  session.ui.pageLoaded = data.ui.pageLoaded
  session.ui.initEventReceived = data.ui.initEventReceived
  session.connection = ConnectionState(
    connected: true,
    reason: ConnectionLossNone,
    detail: cstring""
  )
  session.network = Network(
    futures: JsAssoc[cstring, JsAssoc[cstring, JsObject]]{})
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

proc closeSession*(data: Data, targetIndex: int) =
  ## Close the session at ``targetIndex`` and remove it from the sessions
  ## list.  When the closed session is the active one, we switch to an
  ## adjacent session first.  Refuses to close the last remaining session.
  if data.sessions.len <= 1:
    # Last tab — nothing to close.
    return
  if targetIndex < 0 or targetIndex >= data.sessions.len:
    cwarn "session_switch: closeSession index out of bounds: " &
      $targetIndex & " (have " & $data.sessions.len & " sessions)"
    return

  clog "session_switch: closing session " & $targetIndex &
    " (total before: " & $data.sessions.len & ")"

  # If closing the active session, switch to an adjacent one first.
  if targetIndex == data.activeSessionIndex:
    let newActive = if targetIndex > 0: targetIndex - 1 else: targetIndex + 1
    switchSession(data, newActive)

  # Remove the session from the list.
  data.sessions.delete(targetIndex)

  # Adjust activeSessionIndex after the deletion.
  if data.activeSessionIndex >= data.sessions.len:
    data.activeSessionIndex = data.sessions.len - 1
  elif data.activeSessionIndex > targetIndex:
    data.activeSessionIndex -= 1

  kxi.redraw()

proc switchSession*(data: Data, targetIndex: int) =
  ## Switch from the currently active replay session to ``targetIndex``.
  ##
  ## Does nothing when the target is already active or the index is out
  ## of bounds.  The sequence of operations:
  ##
  ## 1. Save the current session's GL layout snapshot (if layout exists).
  ## 2. Update ``activeSessionIndex`` first so forwarding templates
  ##    point to the new session during the rebuild.
  ## 3. Destroy the OLD session's GL instance and all component state.
  ## 4. Restore the target session's GL layout (may fail for empty
  ##    sessions that have no trace loaded).
  ## 5. Trigger a full Karax redraw.
  if targetIndex == data.activeSessionIndex:
    return
  if targetIndex < 0 or targetIndex >= data.sessions.len:
    cwarn "session_switch: target index out of bounds: " &
      $targetIndex & " (have " & $data.sessions.len & " sessions)"
    return

  clog "session_switch: switching from session " &
    $data.activeSessionIndex & " to " & $targetIndex

  # 1. Save current layout (only if layout exists — nil for empty sessions)
  if not data.ui.layout.isNil:
    saveSessionLayout(data.activeSession, data.ui)

  # 2. Destroy current GL (safe even if layout is nil — the guard in
  #    destroyCurrentLayout handles that case by just clearing the DOM).
  destroyCurrentLayout(data)

  # 3. Switch active session — all Data forwarding templates now resolve
  #    to the target session's fields.
  data.activeSessionIndex = targetIndex

  # 4. Restore target session's layout.  May silently fail for empty
  #    sessions — callInitLayoutSafe catches both Nim and JS errors.
  restoreSessionLayout(data)

  # 5. Full redraw so that every Karax component picks up the new
  #    session's data.
  redrawAll()
