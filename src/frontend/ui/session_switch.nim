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
