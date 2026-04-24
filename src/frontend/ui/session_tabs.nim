## Session tab bar for multi-replay sessions (M10, M12).
##
## Renders a horizontal tab bar above Golden Layout, one tab per
## ``ReplaySession``.  The active session is visually highlighted.
## With a single session (the current default) the bar shows one tab
## so that the user has a discoverable surface for future multi-trace
## workflows.
##
## M12: The "+" button creates a new empty ReplaySession and switches
## to it.  The new session inherits the current layout config so the
## panel arrangement is preserved.

import
  std/[strformat, jsffi],
  karax, karaxdsl, vdom,
  session_switch,
  ../types

from kdom import document, getElementById, Event, stopPropagation

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc sessionLabel(session: ReplaySession, index: int): cstring =
  ## Derive a human-readable label for a session tab.
  ## Prefer the trace program name; fall back to a generic "Trace N".
  if not session.trace.isNil and session.trace.program.len > 0:
    session.trace.program
  else:
    cstring(fmt"Trace {index + 1}")

proc renderSessionTabs*(data: Data): VNode =
  ## Build the virtual-DOM for the session tab bar.
  ##
  ## The bar is a simple flex row of tabs, each containing a label and
  ## (when more than one session exists) a close button.  A trailing
  ## "+" button is included as a placeholder for the future "open new
  ## trace" action.
  buildHtml(tdiv(id = "session-tab-bar", class = "session-tab-bar")):
    for i in 0 ..< data.sessions.len:
      let session = data.sessions[i]
      let isActive = i == data.activeSessionIndex
      let tabClass: cstring =
        if isActive: cstring"session-tab active"
        else:        cstring"session-tab"
      let idx = i  # capture loop variable for the closure
      tdiv(class = tabClass):
        proc onclick(ev: Event, n: VNode) =
          switchSession(data, idx)
        span(class = "session-tab-label"):
          text sessionLabel(session, i)
        # Show the close button only when there are multiple sessions.
        if data.sessions.len > 1:
          span(class = "session-tab-close"):
            proc onclick(ev: Event, n: VNode) =
              ev.stopPropagation()  # Don't trigger tab switch
              closeSession(data, idx)
            text "\u00D7"  # multiplication sign (×)
    # M12: clicking "+" creates a new empty ReplaySession tab.
    tdiv(class = "session-tab-add"):
      proc onclick(ev: Event, n: VNode) =
        createNewSession(data)
      text "+"
