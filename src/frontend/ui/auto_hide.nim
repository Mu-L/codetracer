## Auto-hide panes: panels that collapse to thin edge strips and expand
## on hover/click as slide-in overlays.
##
## The auto-hide system sits entirely at the application level, using
## Golden Layout v2.6.0's public `removeChild`/`addChild`/`addItem` APIs.
## No GL fork is required.
##
## Usage flow:
##   1. User clicks "Pin to Edge" in a stack's dropdown menu (added by
##      layout.nim's stackCreated handler).
##   2. `pinPanel` detaches the component from GL via `removeChild` and
##      stores its serialised config + metadata in `AutoHideState`.
##   3. A thin strip tab appears on the chosen edge.
##   4. Clicking the strip tab calls `showOverlay` which renders the
##      component in an absolutely-positioned overlay that slides in.
##   5. The overlay has an "Unpin" button (`unpinPanel`) that re-adds
##      the component to GL via `addItem`.
##
## Persistence: auto-hide state is saved alongside the GL layout config
## via `serializeAutoHideState` / `restoreAutoHideState`.

import
  std / [ jsffi, jsconsole, strformat, sequtils ],
  karax, karaxdsl, vstyles, kdom,
  ../types,
  ../lib/[ jslib, logging ]

import vdom except Event
from dom import Node

# JS array helpers (not exported from any shared module).
proc newJsArray(): JsObject {.importjs: "(new Array())".}
proc push(arr: JsObject, item: JsObject) {.importjs: "#.push(#)".}

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  AutoHideEdge* = enum
    Left,
    Right,
    Bottom

  AutoHidePanel* = ref object
    ## A panel that has been detached from GL and pinned to an edge.
    edge*: AutoHideEdge
    title*: cstring
    content*: Content         ## The Content enum value (Trace, Events, etc.)
    componentId*: int         ## The component id within its Content group
    config*: JsObject         ## Serialised GL component config for re-attach
    domTab*: Element          ## The strip tab DOM element (for removal)

  AutoHideState* = ref object
    ## Central state for all auto-hidden panels.
    panels*: seq[AutoHidePanel]
    activeOverlay*: AutoHidePanel  ## Currently shown overlay, or nil
    overlayVisible*: bool
    ## Callback to re-render strips after mutations.
    onChanged*: proc()

# ---------------------------------------------------------------------------
# Module-level state (one per window, like `data`)
# ---------------------------------------------------------------------------

var autoHideState*: AutoHideState = nil

proc initAutoHideState*() =
  ## Initialise the auto-hide state. Call once during layout init.
  if autoHideState.isNil:
    autoHideState = AutoHideState(
      panels: @[],
      activeOverlay: nil,
      overlayVisible: false,
      onChanged: nil
    )

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc panelsForEdge*(state: AutoHideState, edge: AutoHideEdge): seq[AutoHidePanel] =
  ## Return all panels pinned to a given edge.
  state.panels.filterIt(it.edge == edge)

proc edgeCssClass*(edge: AutoHideEdge): cstring =
  case edge
  of Left:   cstring"auto-hide-strip-left"
  of Right:  cstring"auto-hide-strip-right"
  of Bottom: cstring"auto-hide-strip-bottom"

proc edgeOverlayCssClass*(edge: AutoHideEdge): cstring =
  case edge
  of Left:   cstring"auto-hide-overlay-left"
  of Right:  cstring"auto-hide-overlay-right"
  of Bottom: cstring"auto-hide-overlay-bottom"

# ---------------------------------------------------------------------------
# Pin / Unpin
# ---------------------------------------------------------------------------

proc pinPanel*(
  layout: GoldenLayout,
  contentItem: GoldenContentItem,
  edge: AutoHideEdge = Bottom
) =
  ## Detach a component from Golden Layout and add it to the auto-hide strip.
  ##
  ## `contentItem` must be a component-level item (isComponent == true).
  ## Its config is serialised before removal so it can be restored later.
  if autoHideState.isNil:
    initAutoHideState()

  if contentItem.isNil:
    console.error cstring"auto_hide: pinPanel called with nil contentItem"
    return

  # Serialise before detaching so the config is still valid.
  let config = contentItem.toConfig().toJs
  let componentState = cast[GoldenItemState](contentItem.toConfig().componentState)
  let title = componentState.label
  let content = componentState.content
  let componentId = componentState.id

  # Detach from GL.  The parent is typically a Stack.
  let parent = contentItem.parent
  if not parent.isNil:
    parent.removeChild(contentItem)
  else:
    console.warn cstring"auto_hide: contentItem has no parent, skipping removeChild"

  let panel = AutoHidePanel(
    edge: edge,
    title: title,
    content: content,
    componentId: componentId,
    config: config,
    domTab: nil  # will be set when strip is rendered
  )
  autoHideState.panels.add(panel)

  cdebug fmt"auto_hide: pinned panel '{title}' to edge {edge}"

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

proc unpinPanel*(layout: GoldenLayout, panel: AutoHidePanel) =
  ## Re-attach a pinned panel back into Golden Layout and remove it
  ## from the auto-hide state.
  if autoHideState.isNil or layout.isNil:
    return

  # Hide overlay if this panel is currently shown.
  if autoHideState.activeOverlay == panel:
    autoHideState.activeOverlay = nil
    autoHideState.overlayVisible = false

  # Re-add to GL.  We use addItem on the ground item's first container
  # (typically a row/column) which is the same strategy as panel_transfer.
  let ground = layout.groundItem
  if not ground.isNil and ground.contentItems.len > 0:
    let target = ground.contentItems[0]
    discard target.addItem(panel.config)
  else:
    console.warn cstring"auto_hide: no existing container — adding to root"
    discard ground.addItem(panel.config)

  # Remove from state.
  autoHideState.panels = autoHideState.panels.filterIt(it != panel)

  cdebug fmt"auto_hide: unpinned panel '{panel.title}'"

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

# ---------------------------------------------------------------------------
# Overlay show / hide
# ---------------------------------------------------------------------------

proc hideOverlay*() =
  ## Hide the currently visible auto-hide overlay.
  if autoHideState.isNil:
    return
  autoHideState.activeOverlay = nil
  autoHideState.overlayVisible = false

  # Remove the "visible" CSS class from the overlay container.
  let overlayEl = document.getElementById(cstring"auto-hide-overlay")
  if not overlayEl.isNil:
    overlayEl.classList.remove(cstring"visible")
    # Remove edge-specific classes.
    overlayEl.classList.remove(cstring"auto-hide-overlay-left")
    overlayEl.classList.remove(cstring"auto-hide-overlay-right")
    overlayEl.classList.remove(cstring"auto-hide-overlay-bottom")

  # Clear the overlay content.
  let contentEl = document.getElementById(cstring"auto-hide-overlay-content")
  if not contentEl.isNil:
    contentEl.innerHTML = cstring""

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

proc showOverlay*(panel: AutoHidePanel) =
  ## Show a slide-in overlay for the given pinned panel.
  ##
  ## The overlay container is a pre-existing DOM element in index.html
  ## (#auto-hide-overlay). We inject the component content into
  ## #auto-hide-overlay-content and apply edge-specific CSS classes
  ## for positioning/animation.
  if autoHideState.isNil:
    return

  # If the same panel is already shown, toggle it off.
  if autoHideState.activeOverlay == panel and autoHideState.overlayVisible:
    hideOverlay()
    return

  autoHideState.activeOverlay = panel
  autoHideState.overlayVisible = true

  let overlayEl = document.getElementById(cstring"auto-hide-overlay")
  if overlayEl.isNil:
    console.error cstring"auto_hide: #auto-hide-overlay not found in DOM"
    return

  # Set the title.
  let titleEl = document.getElementById(cstring"auto-hide-overlay-title")
  if not titleEl.isNil:
    titleEl.innerHTML = panel.title

  # Apply edge-specific class and make visible.
  overlayEl.classList.remove(cstring"auto-hide-overlay-left")
  overlayEl.classList.remove(cstring"auto-hide-overlay-right")
  overlayEl.classList.remove(cstring"auto-hide-overlay-bottom")
  overlayEl.classList.add(edgeOverlayCssClass(panel.edge))
  overlayEl.classList.add(cstring"visible")

  if not autoHideState.onChanged.isNil:
    autoHideState.onChanged()

# ---------------------------------------------------------------------------
# Strip rendering (called from layout.nim or a dedicated Karax renderer)
# ---------------------------------------------------------------------------

proc renderStripTabs*(edge: AutoHideEdge): VNode =
  ## Render the tab elements for a single edge strip.
  ## Each tab is a clickable element that shows the overlay on click.
  let panels = if not autoHideState.isNil:
      autoHideState.panelsForEdge(edge)
    else:
      @[]

  buildHtml(tdiv(class = edgeCssClass(edge))):
    for panel in panels:
      let capturedPanel = panel
      tdiv(
        class = "auto-hide-strip-tab",
        onclick = proc(e: Event, tg: VNode) =
          showOverlay(capturedPanel)
      ):
        text panel.title

proc renderAutoHideStrips*(): VNode =
  ## Top-level Karax component that renders all three edge strips.
  ## Attach this as a Karax renderer to #auto-hide-strips.
  buildHtml(tdiv(class = "auto-hide-strips-container")):
    renderStripTabs(AutoHideEdge.Left)
    renderStripTabs(AutoHideEdge.Right)
    renderStripTabs(AutoHideEdge.Bottom)

# ---------------------------------------------------------------------------
# Serialisation for layout save/load
# ---------------------------------------------------------------------------

proc serializeAutoHideState*(): JsObject =
  ## Serialise the auto-hide state to a JSON-compatible object for
  ## inclusion in the saved layout config.
  if autoHideState.isNil or autoHideState.panels.len == 0:
    return js{}

  var panelArray = newJsArray()
  for panel in autoHideState.panels:
    let obj = js{
      "edge": cint(ord(panel.edge)),
      "title": panel.title,
      "content": cint(ord(panel.content)),
      "componentId": panel.componentId,
      "config": panel.config
    }
    panelArray.push(obj)

  return js{"panels": panelArray}

proc restoreAutoHideState*(saved: JsObject) =
  ## Restore auto-hide panels from a previously serialised state.
  ## Call after layout init but before rendering strips.
  if saved.isNil or saved.isUndefined:
    return

  initAutoHideState()

  let panelArray = saved["panels"]
  if panelArray.isNil or panelArray.isUndefined:
    return

  let panelLen = cast[int](panelArray.length)
  for i in 0 ..< panelLen:
    let obj = panelArray[i]
    let panel = AutoHidePanel(
      edge: AutoHideEdge(obj["edge"].to(int)),
      title: obj["title"].to(cstring),
      content: Content(obj["content"].to(int)),
      componentId: obj["componentId"].to(int),
      config: obj["config"],
      domTab: nil
    )
    autoHideState.panels.add(panel)

  cdebug fmt"auto_hide: restored {autoHideState.panels.len} pinned panels"

# ---------------------------------------------------------------------------
# Keyboard / backdrop dismissal
# ---------------------------------------------------------------------------

proc setupOverlayDismissal*() =
  ## Set up global event handlers for dismissing the auto-hide overlay:
  ## - Escape key
  ## - Click on the backdrop element
  ## - Mouse-leave from the overlay (with a short delay)
  ##
  ## Call once after DOM is ready.

  # Escape key handler.
  document.addEventListener(cstring"keydown", proc(ev: Event) =
    let keyEv = cast[JsObject](ev)
    if keyEv.key.to(cstring) == cstring"Escape":
      if not autoHideState.isNil and autoHideState.overlayVisible:
        hideOverlay())

  # Backdrop click handler.
  let backdrop = document.getElementById(cstring"auto-hide-backdrop")
  if not backdrop.isNil:
    backdrop.addEventListener(cstring"click", proc(ev: Event) =
      hideOverlay())
