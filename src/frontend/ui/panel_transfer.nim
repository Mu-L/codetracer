## M21/M22: Cross-window panel transfer via context menu.
##
## Provides "Send to Window" functionality on Golden Layout tab context menus.
## When a user right-clicks a GL tab, they can choose a target window from a
## submenu. The panel's config is serialised, removed from the source window,
## and recreated in the target window via Electron IPC.
##
## The panel carries its `sessionId` so that mixed-session windows (M22) route
## DAP events through the correct ReplaySession.

import
  std / [ jsffi, jsconsole, strformat, asyncjs ],
  kdom,
  ../types,
  ../lib/[ jslib ]

# ---------------------------------------------------------------------------
# Electron IPC access (renderer side)
# ---------------------------------------------------------------------------

var electron* {.importc.}: JsObject

proc ipcRenderer(): JsObject =
  ## Lazily obtain the ipcRenderer; returns nil/undefined when not in Electron.
  if not electron.isNil and not electron.isUndefined:
    return electron.ipcRenderer
  return nil

# ---------------------------------------------------------------------------
# Panel config serialisation
# ---------------------------------------------------------------------------

proc serializePanelConfig*(contentItem: GoldenContentItem): JsObject =
  ## Serialise a GL component's config + state for cross-window transfer.
  ## The returned JsObject is a plain JSON-compatible config that can be
  ## sent over IPC and used with `layout.addItem` on the receiving side.
  contentItem.toConfig().toJs

# ---------------------------------------------------------------------------
# Receiving side: attach a panel that arrived from another window
# ---------------------------------------------------------------------------

proc handlePanelAttach*(layout: GoldenLayout, config: JsObject) =
  ## Receive a panel config from another window and add it to the local
  ## Golden Layout instance.  The config is added to the first available
  ## stack, or as a new stack at the root if the layout is empty.
  if layout.isNil:
    console.error cstring"panel_transfer: cannot attach — layout is nil"
    return

  # Try to add to the ground item's first content item (typically a stack/row/column).
  let ground = layout.groundItem
  if not ground.isNil and ground.contentItems.len > 0:
    let target = ground.contentItems[0]
    discard target.addItem(config)
  else:
    console.warn cstring"panel_transfer: no existing container — adding to root"
    discard ground.addItem(config)

# ---------------------------------------------------------------------------
# Sending side: detach a panel and send it to another window
# ---------------------------------------------------------------------------

proc detachAndSendPanel*(
  contentItem: GoldenContentItem,
  targetWindowId: int,
  sessionId: int
) =
  ## Serialise the panel, remove it from the local GL instance, and send
  ## it to the target window via the main process.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    console.error cstring"panel_transfer: ipcRenderer not available"
    return

  let config = serializePanelConfig(contentItem)
  let payload = js{
    "targetWindowId": targetWindowId,
    "panelConfig": config,
    "sessionId": sessionId
  }

  # Remove the panel from the local GL instance.
  if not contentItem.parent.isNil:
    contentItem.parent.removeChild(contentItem)

  ipc.send(cstring"CODETRACER::panel-detach", payload)

# ---------------------------------------------------------------------------
# Context menu: "Send to Window" submenu
# ---------------------------------------------------------------------------

proc emptyWindowList(): JsObject {.importjs: "({windows: []})".}

proc requestWindowList*(): Future[JsObject] =
  ## Ask the main process for the list of open windows.
  ## Returns a promise that resolves with `{ windows: [{ id, title }] }`.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    return newPromise(proc(resolve: proc(v: JsObject)) =
      resolve(emptyWindowList()))

  return newPromise(proc(resolve: proc(v: JsObject)) =
    # Use ipcRenderer.once so the handler is automatically cleaned up.
    ipc.once(cstring"CODETRACER::list-windows-reply", proc(event: JsObject, response: JsObject) =
      resolve(response))
    ipc.send(cstring"CODETRACER::list-windows", js{}))

proc buildSendToWindowMenuItems*(
  contentItem: GoldenContentItem,
  sessionId: int,
  windows: JsObject
): seq[ContextMenuItem] =
  ## Build context menu items for each available target window.
  var items: seq[ContextMenuItem] = @[]
  let winArray = windows["windows"]
  let winLen = cast[int](winArray.length)

  for i in 0 ..< winLen:
    let win = winArray[i]
    let windowId = win["id"].to(int)
    let windowTitle = win["title"].to(cstring)
    let label = cstring(fmt"Send to: {windowTitle}")
    # Capture windowId for closure.
    let capturedWindowId = windowId
    let capturedSessionId = sessionId
    let capturedItem = contentItem
    items.add(ContextMenuItem(
      name: label,
      hint: cstring"",
      handler: proc(ev: kdom.Event) =
        detachAndSendPanel(capturedItem, capturedWindowId, capturedSessionId)
    ))

  if items.len == 0:
    items.add(ContextMenuItem(
      name: cstring"No other windows",
      hint: cstring"",
      handler: proc(ev: kdom.Event) = discard
    ))

  return items

# ---------------------------------------------------------------------------
# IPC listener for the receiving side (renderer process)
# ---------------------------------------------------------------------------

proc registerPanelAttachHandler*(layout: GoldenLayout) =
  ## Register the IPC handler that listens for incoming panel configs
  ## from other windows.  Call this once after the GL layout is initialised.
  let ipc = ipcRenderer()
  if ipc.isNil or ipc.isUndefined:
    return

  ipc.on(cstring"CODETRACER::panel-attach", proc(event: JsObject, payload: JsObject) =
    let config = payload["panelConfig"]
    # M22: the payload carries sessionId so the panel can be associated
    # with the correct ReplaySession in the target window.  For now we
    # log it; full routing will be wired when mixed-session panels are
    # rendered with per-session event subscriptions.
    let sid = payload["sessionId"]
    console.log cstring"panel_transfer: attaching panel from session ", sid
    handlePanelAttach(layout, config))
