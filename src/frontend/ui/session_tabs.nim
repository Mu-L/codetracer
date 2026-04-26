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
  std/[strformat, strutils, jsffi],
  karax, karaxdsl, vdom,
  session_switch,
  ../types

from kdom import document, getElementById, Event, stopPropagation

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const tabIdPrefix = "session-tab-"

proc tabIndexFromId(id: cstring): int =
  ## Extract the integer session index from a tab element id like
  ## ``"session-tab-3"``.  Returns -1 if the id is malformed.
  let s = $id
  if s.startsWith(tabIdPrefix):
    try:
      return parseInt(s[tabIdPrefix.len .. ^1])
    except ValueError:
      discard
  return -1

# ---------------------------------------------------------------------------
# Post-render native click handler attachment
# ---------------------------------------------------------------------------

proc attachTabClickHandlers*(data: Data) =
  ## Attach native DOM click handlers to every ``.session-tab`` element.
  ##
  ## This is the primary mechanism that ensures tab clicks always call
  ## ``switchSession``.  The Nim JS backend compiles closures inside
  ## for-loops into a **single shared closure environment**, so a
  ## ``let idx = i`` captured inside the loop body ends up pointing to
  ## the **last** loop index by the time any handler fires (the classic
  ## JS closure-in-loop bug).  We avoid this by using raw JS that creates
  ## a proper per-iteration closure via an IIFE.
  ##
  ## Called after every Karax redraw of the tab bar via the post-render
  ## callback registered in ``layout.nim``.
  {.emit: ["""
    (function() {
      var tabBar = document.getElementById('session-tab-bar');
      if (!tabBar) return;
      var tabs = tabBar.querySelectorAll('.session-tab');
      var switchFn = """, switchSession, """;
      var dataRef = """, data, """;
      for (var i = 0; i < tabs.length; i++) {
        (function(idx) {
          tabs[idx].addEventListener('click', function(ev) {
            switchFn(dataRef, idx);
          });
        })(i);
      }
    })();
  """].}

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
  ##
  ## **Note on click handlers:**  The ``proc onclick`` closures below
  ## read the session index from the VNode's ``id`` attribute at click
  ## time rather than from a captured loop variable.  The Nim JS backend
  ## compiles all closures in a ``buildHtml`` for-loop to share one
  ## environment object, so a captured ``let idx = i`` would always
  ## resolve to the *last* iteration's value (classic JS closure-in-loop
  ## bug).  As a belt-and-suspenders measure, ``attachTabClickHandlers``
  ## also adds native DOM click handlers after each render.
  let barClass: cstring =
    if data.sessions.len <= 1: cstring"session-tab-bar single-session"
    else:                      cstring"session-tab-bar"
  buildHtml(tdiv(id = "session-tab-bar", class = barClass)):
    for i in 0 ..< data.sessions.len:
      let session = data.sessions[i]
      let isActive = i == data.activeSessionIndex
      let tabClass: cstring =
        if isActive: cstring"session-tab active"
        else:        cstring"session-tab"
      tdiv(class = tabClass, id = cstring(tabIdPrefix & $i)):
        proc onclick(ev: Event, n: VNode) =
          # Derive the session index from the VNode id rather than a
          # closure-captured loop variable.  See module docstring for why.
          let clickedIdx = tabIndexFromId(n.id)
          if clickedIdx >= 0:
            switchSession(data, clickedIdx)
        span(class = "session-tab-label"):
          text sessionLabel(session, i)
        # Show the close button only when there are multiple sessions.
        if data.sessions.len > 1:
          span(class = "session-tab-close"):
            proc onclick(ev: Event, n: VNode) =
              ev.stopPropagation()  # Don't trigger tab switch
              # The close button's VNode doesn't carry the parent tab's
              # id, so walk up the DOM from the event target to find the
              # enclosing session-tab-N element and extract the index.
              var targetIdx = -1
              {.emit: [targetIdx, """ = (function() {
                var el = """, ev, """.currentTarget || """, ev, """.target;
                while (el) {
                  if (el.id && el.id.startsWith('""", tabIdPrefix, """')) {
                    return parseInt(el.id.substring(""", tabIdPrefix.len, """));
                  }
                  el = el.parentElement;
                }
                return -1;
              })();"""].}
              if targetIdx >= 0:
                closeSession(data, targetIdx)
            text "\u00D7"  # multiplication sign (×)
    # M12: clicking "+" creates a new empty ReplaySession tab.
    tdiv(class = "session-tab-add"):
      proc onclick(ev: Event, n: VNode) =
        createNewSession(data)
      text "+"
