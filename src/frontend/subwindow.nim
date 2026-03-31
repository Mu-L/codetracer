import
  std/[ jsffi, jsconsole, asyncjs, strformat, strutils ],
  karax, vdom, karaxdsl, kdom, vstyles, dom, jsffi, jsconsole, paths,
  types, lang,
  results,
  utils

when defined(linux):
  var startMenuChecked = true
  var bpfChecked = true
  var agentHarborChecked = true

var pathChecked = true
var dontAskChecked = false

type
  StepInfo = object
    ## Tracks the status of one install step for the progress display.
    step: string      ## e.g. "path", "desktop", "bpf", "agent-harbor"
    status: string    ## "started", "completed", "failed", "skipped"
    message: string   ## Human-readable description

var installSteps: seq[StepInfo] = @[]
var installOverallStatus = ""  ## "", "installing", "ok", "problem"

var electron* {.importc.}: JsObject
let ipc = electron.ipcRenderer

proc closeWindow() {.importjs: "window.close()".}

proc onDismiss() =
  ipc.send("CODETRACER::dismiss-ct-frontend", dontAskChecked.toJs)

  closeWindow()

proc onInstall() =

  let options: JsObject = js{}

  when defined(linux):
    if startMenuChecked:
      options["desktop"] = true
    options["bpf"] = bpfChecked
    options["agent-harbor"] = agentHarborChecked

  if pathChecked:
    options["path"] = true

  ipc.send("CODETRACER::install-ct-frontend", options)
  installOverallStatus = "installing"

proc stepDisplayName(step: string): string =
  ## Returns a user-friendly label for each install step.
  case step
  of "path": "PATH setup"
  of "desktop": "Desktop file"
  of "bpf": "BPF monitoring"
  of "agent-harbor": "Agent Harbor"
  else: step

proc stepStatusIcon(status: string): string =
  case status
  of "started": "..."
  of "completed": "OK"
  of "failed": "FAILED"
  of "skipped": "skipped"
  else: ""

proc installStatusView: VNode =
  buildHtml(tdiv(class = "dialog-install-status")):
    if installSteps.len == 0 and installOverallStatus == "installing":
      tdiv(class = "dialog-install-status-installing"):
        text "Installing..."
    else:
      for step in installSteps:
        let statusClass = "install-step-" & step.status
        buildHtml(tdiv(class = fmt"install-step {statusClass}")):
          span(class = "step-icon"):
            text stepStatusIcon(step.status)
          span(class = "step-name"):
            text stepDisplayName(step.step)
          if step.message.len > 0 and step.status == "failed":
            span(class = "step-message"):
              text " — " & step.message
      if installOverallStatus == "ok":
        tdiv(class = "dialog-install-status-ok"):
          text "Installation complete."
      elif installOverallStatus == "problem":
        tdiv(class = "dialog-install-status-problem"):
          text "Installation encountered errors."

proc dialogBox(): VNode =
  echo "codetracerPrefix: ", codetracerPrefix
  buildHtml(tdiv):
    tdiv(class="dialog-box"):
      tdiv(class="dialog-header"):
        img(
          src="./public/resources/shared/" &
            "codetracer_welcome_logo.svg",
          class="dialog-icon")
      tdiv(class="dialog-content"):
          text "CodeTracer is not installed."
          br()
          text "Do you want to install it now?"
      if installOverallStatus == "":
        tdiv(class="dialog-options"):
          when defined(linux):
            label:
              input(
                `type`="checkbox",
                checked=toChecked(startMenuChecked),
                onClick=proc() =
                  startMenuChecked =
                    not startMenuChecked)
              text "Add CodeTracer to my start menu"
              span(class="info-icon"):
                text "ⓘ "
                tdiv(
                  class = "custom-tooltip",
                ):
                  text "This will install a " &
                    ".desktop file in " &
                    "~/.local/share/applications"
                  br()
                  text "which will exec the binary you ran this executable with"
          label:
            input(
              `type`="checkbox",
              checked=toChecked(pathChecked),
              onClick=proc() =
                pathChecked = not pathChecked)
            text "Add the ct command to my PATH"
            span(class="info-icon"):
              text "ⓘ "
              tdiv(
                class = "custom-tooltip",
              ):
                text "This will create a symlink" &
                  " to the current executable" &
                  " in ~/.local/bin"
          when defined(linux):
            label:
              input(
                `type`="checkbox",
                checked=toChecked(bpfChecked),
                onClick=proc() =
                  bpfChecked = not bpfChecked)
              text "Enable BPF process monitoring (requires admin password)"
              span(class="info-icon"):
                text "ⓘ "
                tdiv(
                  class = "custom-tooltip",
                ):
                  text "Sets up BPF capabilities for" &
                    " process tree monitoring."
                  br()
                  text "Requires sudo for initial" &
                    " setup. Can be skipped" &
                    " and configured later."
            label:
              input(
                `type`="checkbox",
                checked=toChecked(agentHarborChecked),
                onClick=proc() =
                  agentHarborChecked =
                    not agentHarborChecked)
              text "Install Agent Harbor (requires admin password)"
              span(class="info-icon"):
                text "ⓘ "
                tdiv(
                  class = "custom-tooltip",
                ):
                  text "Installs Agent Harbor for" &
                    " AI-powered debugging."
                  br()
                  text "Downloads the official" &
                    " installer. Requires sudo."
        tdiv(class="dialog-actions"):
          button(class="install-btn", onClick=onInstall): text "Install"
          button(class="dismiss-btn", onClick=onDismiss): text "Dismiss"
        tdiv(class="dialog-options dialog-ask-again"):
          label:
              text "Don't ask me again!"
              input(
                `type`="checkbox",
                checked=toChecked(dontAskChecked),
                onClick=proc() = dontAskChecked = not dontAskChecked
              )
      else:
        installStatusView()
        if installOverallStatus in ["ok", "problem"]:
          tdiv(class="dialog-actions"):
            button(class="dismiss-btn", onClick=onDismiss): text "Close"

proc main(): VNode =
  buildHtml(tdiv):
    dialogBox()

proc onCtInstallStatus(sender: js, data: js) =
  ## Handles install progress events from the main process.
  ## Accepts two formats:
  ##   - Step event: {kind: "step", step: "...", status: "...", message: "..."}
  ##   - Done event: {kind: "done", status: "ok"|"problem"}
  let kind = $cast[cstring](data["kind"])
  if kind == "step":
    let info = StepInfo(
      step: $cast[cstring](data["step"]),
      status: $cast[cstring](data["status"]),
      message: $cast[cstring](data["message"]),
    )
    # Update existing step or append new one.
    var found = false
    for i in 0 ..< installSteps.len:
      if installSteps[i].step == info.step:
        installSteps[i] = info
        found = true
        break
    if not found:
      installSteps.add(info)
  elif kind == "done":
    installOverallStatus = $cast[cstring](data["status"])
  redraw()

ipc.on("CODETRACER::ct-install-status", onCtInstallStatus)

setRenderer(main, "ROOT")
