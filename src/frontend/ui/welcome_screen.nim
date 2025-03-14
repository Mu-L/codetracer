import
  ../ui_helpers,
  ../../ct/version, 
  ui_imports, ../types

proc recentProjectView(self: WelcomeScreenComponent, trace: Trace): VNode =
  buildHtml(
    tdiv(
      class = "recent-trace",
      onclick = proc =
        self.loading = true
        self.loadingTrace = trace
        data.redraw()
        self.data.ipc.send "CODETRACER::load-recent-trace", js{ traceId: trace.id }
    )
  ):
    let programLimitName = 45 
    let limitedProgramName = if trace.program.len > programLimitName:
        ".." & ($trace.program)[^programLimitName..^1]
      else:
        $trace.program

    tdiv(class = "recent-trace-title"):
      span(class = "recent-trace-title-id"):
        text fmt"ID: {trace.id}"
      separateBar()
      span(class = "recent-trace-title-content"):
        text limitedProgramName # TODO: tippy
    # tdiv(class = "recent-trace-info"):
    #   tdiv(class = "recent-trace-date"):
    #     text trace.date
    #   if not trace.duration.isNil:
    #     tdiv(class = "recent-trace-duration"):
    #       text trace.duration

proc recentProjectsView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "recent-traces")
  ):
    tdiv(class = "recent-traces-title"):
      text "RECENT TRACES"
    if self.data.recentTraces.len > 0:
      for trace in self.data.recentTraces:
        recentProjectView(self, trace)
    else:
      tdiv(class = "no-recent-traces"):
        text "No traces yet."

proc renderOption(self: WelcomeScreenComponent, option: WelcomeScreenOption): VNode =
  let optionClass = toLowerAscii($(option.name)).split().join("-")
  let inactiveClass = if not option.inactive: "" else: "inactive-start-option"
  var containerClass = &"start-option {optionClass} {inactiveClass}"
  var iconClass = &"start-option-icon {optionClass}-icon"
  var nameClass = "start-option-name"

  if option.hovered:
    containerClass = containerClass & " hovered"
    iconClass = iconClass & " hovered"
    nameClass = nameClass & " hovered"

  buildHtml(
    tdiv(
      class = containerClass,
      onmousedown = proc(ev: Event, tg: VNode) =
        ev.preventDefault(),
      onmouseup = proc(ev: Event, tg: VNode) =
        ev.preventDefault()
        option.hovered = false,
      onclick = proc(ev: Event, tg: VNode) =
        ev.preventDefault()
        option.command(),
      onmouseover = proc = option.hovered = true,
      onmouseleave = proc = option.hovered = false
    )
  ):
    tdiv(class = nameClass):
      text &"{option.name}"

proc renderStartOptions(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "start-options")
  ):
    for option in self.options:
      renderOption(self, option)

template customCheckbox*(obj: untyped, name: string) = discard

proc renderFormCheckboxRow(
  parameterName: cstring,
  label: cstring,
  condition: bool,
  handler: proc,
  disabled: bool = true
): VNode =
  buildHtml(
    tdiv(class = "new-record-form-row")
  ):
    tdiv(class = "new-record-input-row"):
      input(
        name = parameterName,
        `type` = "checkbox",
        class = "checkbox",
        checked = toChecked(condition),
        value = parameterName
      )
      span(
        class = "checkmark",
        onclick = proc =
          handler()
      )
      label(`for` = parameterName):
        text &"{label}"

proc renderInputRow(
  parameterName: cstring,
  label: cstring,
  buttonText: cstring,
  buttonHandler: proc(ev: Event, tg: VNode),
  inputHandler: proc(ev: Event, tg: Vnode),
  inputText: cstring = "",
  validationMessage: cstring = "",
  disabled: bool = false,
  hasButton: bool = true,
  validInput: bool = true
): VNode =
  var class: cstring = ""

  if disabled: class = class & "disabled"
  if not validInput: class = class & " invalid"

  buildHtml(
    tdiv(class = "new-record-form-row")
  ):
    tdiv(class = "new-record-input-row"):
      input(
        `type` = "text",
        id = inputText,
        class = class,
        name = parameterName,
        value = inputText,
        onchange = inputHandler,
        placeholder = &"{label}"
      )
      if hasButton:
        button(
          class = class,
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            buttonHandler(ev,tg)
        ): text(buttonText)

proc chooseExecutable(self: WelcomeScreenComponent) =
  self.data.ipc.send "CODETRACER::load-path-for-record", js{ fieldName: cstring("executable") }

proc chooseDir(self: WelcomeScreenComponent, fieldName: cstring) =
  self.data.ipc.send "CODETRACER::choose-dir", js{ fieldName: fieldName }

proc renderRecordResult(self: WelcomeScreenComponent): VNode =
  var containerClass = "new-record-result"
  var iconClass = "new-record-status-icon"
  case self.newRecord.status.kind:
  of RecordInit:
    containerClass = containerClass & " empty"
    iconClass = iconClass & " empty"

  of RecordError:
    containerClass = containerClass & " failed"
    iconClass = iconClass & " failed"

  of RecordSuccess:
    containerClass = containerClass & " success"
    iconClass = iconClass & " success"

  of InProgress:
    containerClass = containerClass & " in-progress"
    iconClass = iconClass & " in-progress"

  buildHtml(
    tdiv(class = containerClass)
  ):
    tdiv(class = iconClass)
    tdiv(class = &"new-record-{self.newRecord.status.kind}-message"):
      case self.newRecord.status.kind:
      of InProgress:
        text &"Recording..."

      of RecordError:
        text &"Record failed. Error: {self.newRecord.status.errorMessage}"

      of RecordSuccess:
        text &"Record successful! Opening..."

      else:
        discard

proc prepareArgs(self: WelcomeScreenComponent): seq[cstring] =
  var args: seq[cstring] = @[]
  var outputDir = ""

  if not self.newRecord.defaultOutputFolder:
    args.add(cstring("-o"))
    args.add(self.newRecord.outputFolder)

  args.add(self.newRecord.executable)

  return args.concat(self.newRecord.args)

proc newRecordFormView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "new-record-form")
  ):
    # TODO: two separate dialogs for executable and project folder?
    # read https://www.electronjs.org/docs/latest/api/dialog , Note: On Windows and Linux..
    # (it seems an open dialog can't select both files and directories there)
    renderInputRow(
      "executable",
      "Local project path",
      "Choose",
      proc(ev: Event, tg: VNode) = chooseExecutable(self),
      proc(ev: Event, tg: VNode) =
        self.newRecord.executable = ev.target.value
        self.data.ipc.send("CODETRACER::path-validation",
          js{
            path: ev.target.value,
            fieldName: cstring("executable"),
            required: self.newRecord.formValidator.requiredFields[cstring("executable")]}),
      inputText = self.newRecord.executable,
      validationMessage = self.newRecord.formValidator.invalidExecutableMessage,
      validInput = self.newRecord.formValidator.validExecutable
    )
    renderInputRow(
      "args",
      "Command line arguments",
      "",
      proc(ev: Event, tg: VNode) = discard,
      proc(ev: Event, tg: VNode) = self.newRecord.args = ev.target.value.split(" "),
      hasButton = false,
      inputText = self.newRecord.args.join(j" ")
    )
    renderInputRow(
      "workDir",
      "Working directory",
      "Choose",
      proc(ev: Event, tg: VNode) = chooseDir(self, cstring("workDir")),
      proc(ev: Event, tg: VNode) =
        self.newRecord.workDir = ev.target.value
        self.data.ipc.send("CODETRACER::path-validation",
          js{
            path: ev.target.value,
            fieldName: cstring("workDir"),
            required: self.newRecord.formValidator.requiredFields[cstring("workDir")]}),
      inputText = self.newRecord.workDir,
      validationMessage = self.newRecord.formValidator.invalidWorkDirMessage,
      validInput = self.newRecord.formValidator.validWorkDir
    )
    renderFormCheckboxRow(
      "defaultOutputFolder",
      "Use default output folder",
      self.newRecord.defaultOutputFolder,
      proc = (self.newRecord.defaultOutputFolder = not self.newRecord.defaultOutputFolder)
    )
    renderInputRow(
      "outputFolder",
      "Output folder",
      "Choose",
      proc(ev: Event, tg: VNode) = chooseDir(self, cstring("outputFolder")),
      proc(ev: Event, tg: VNode) =
        self.newRecord.outputFolder = ev.target.value
        self.data.ipc.send("CODETRACER::path-validation",
          js{
            path: ev.target.value,
            fieldName: cstring("outputFolder"),
            required: self.newRecord.formValidator.requiredFields[cstring("outputFolder")]}),
      inputText =
        if self.newRecord.defaultOutputFolder:
          cstring"/home/<user>/.local/codetracer/"
        else:
          self.newRecord.outputFolder,
      validationMessage = self.newRecord.formValidator.invalidOutputFolderMessage,
      validInput = self.newRecord.formValidator.validOutputFolder,
      disabled = self.newRecord.defaultOutputFolder
    )
    renderRecordResult(self)
    case self.newRecord.status.kind:
    of RecordInit, RecordError:
      tdiv(class = "new-record-form-row"):
        button(
          class = "cancel-button",
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            self.welcomeScreen = true
            self.newRecordScreen = false
            self.newRecord = nil
        ):
          text "Back"
        button(
          class = "confirmation-button",
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            self.newRecord.status.kind = InProgress
            let workDir = if self.newRecord.workDir.isNil or self.newRecord.workDir.len == 0:
                jsUndefined
              else:
                cast[JsObject](self.newRecord.workDir)
            self.data.ipc.send(
                "CODETRACER::new-record", js{
                  args: prepareArgs(self),
                  options: js{ cwd: workDir }
                }
            )
        ):
          text "Run"

    of InProgress:
      tdiv(class = "new-record-form-row"):
        button(
          class = "record-stop-button",
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            self.data.ipc.send "CODETRACER::stop-recording-process"
            self.newRecord.status.kind = RecordError
            self.newRecord.status.errorMessage = "Cancelled by the user."
        ):
          text "Stop"

    else:
      discard

proc dirExist(self: WelcomeScreenComponent, path: cstring): bool = discard

proc newRecordView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "new-record-screen")
  ):
    tdiv(class = "new-record-screen-content"):
      tdiv(class = "welcome-logo")
      tdiv(class = "new-record-title"):
        text "Start Debugger"
      newRecordFormView(self)

proc loadInitialOptions(self: WelcomeScreenComponent) =
  self.options = @[
    WelcomeScreenOption(
      name: "Record new trace",
      command: proc =
        self.welcomeScreen = false
        self.newRecordScreen = true
        self.newRecord = NewTraceRecord(
          defaultOutputFolder: true,
          status: RecordStatus(kind: RecordInit),
          args: @[],
          executable: cstring"",
          formValidator: RecordScreenFormValidator(
            validExecutable: true,
            invalidExecutableMessage: cstring(""),
            validOutputFolder: true,
            invalidOutputFolderMessage: cstring(""),
            validWorkDir: true,
            invalidWorkDirMessage: cstring(""),
            requiredFields: JsAssoc[cstring,bool]{
              "executable": true,
              "workDir": false,
              "outputFolder": false
            }
          )
        )
    ),
    WelcomeScreenOption(
      name: "Open local trace",
      command: proc =
        self.data.ipc.send "CODETRACER::open-local-trace"
    ),
    WelcomeScreenOption(
      name: "Open online trace",
      inactive: true,
      command: proc = discard
    ),
    WelcomeScreenOption(
      name: "CodeTracer shell",
      inactive: true,
      command: proc =
        self.data.ui.welcomeScreen.loading = true
        self.data.ipc.send "CODETRACER::load-codetracer-shell"
    )
  ]

proc welcomeScreenView(self: WelcomeScreenComponent): VNode =
  var class = "welcome-screen"

  if self.loading:
    class = class & " welcome-screen-loading"

  buildHtml(
    tdiv(
      id = "welcome-screen",
      class = class
    )
  ):
    tdiv(class = "welcome-title"):
      tdiv(class = "welcome-text"):
        tdiv(class = "welcome-logo")
        text "Welcome to CodeTracer IDE"
      tdiv(class = "welcome-version"):
        text fmt"Version {CodeTracerVersionStr}" # TODO include dynamically from e.g. version.nim
    tdiv(class = "welcome-content"):
      recentProjectsView(self)
      renderStartOptions(self)

proc loadingOverlay(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "welcome-screen-loading-overlay")
  ):
    tdiv(class = "welcome-screen-loading-overlay-icon")
    tdiv(class = "welcome-screen-loading-overlay-text"):
      tdiv(): text "Loading trace..."

method render*(self: WelcomeScreenComponent): VNode =
  if self.data.ui.welcomeScreen.isNil:
    return
  if self.options.len == 0:
    self.loadInitialOptions()

  buildHtml(tdiv()):
    if self.welcomeScreen or self.newRecordScreen:
      tdiv(class = "welcome-screen-wrapper"):
        windowMenu(data, true)
        if self.welcomeScreen:
          welcomeScreenView(self)
        elif self.newRecordScreen:
          newRecordView(self)

      if self.loading:
        loadingOverlay(self)
