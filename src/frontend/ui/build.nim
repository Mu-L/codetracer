import ui_imports, ../types

proc focusBuild*(self: BuildComponent) =
  ## Activate the build pane in the GL layout using the component mapping.
  ## This avoids hard-coded tree indices and works regardless of layout structure.
  if not self.data.ui.layout.isNil:
    self.data.openLayoutTab(Content.Build)

proc matchLocation*(self: BuildComponent, raw: string): (bool, types.Location, cstring, cstring) =
  var l = types.Location(line: 0)
  if "Hint" in raw:
    return (false, l, cstring"", cstring"")

  if raw.startsWith("/"):
    var after = raw.find(") ")

    if after != -1:
      var maybeLocation = raw[0 .. after]
      var left = maybeLocation.find("(")

      if left != -1:
        try:
          let space = maybeLocation.find(", ")
          var line = -1
          var column = -1

          if space != -1:
            line = maybeLocation[left + 1 ..< space].parseInt
            column = maybeLocation[space + 2 ..< after].parseInt

          else:
            line = maybeLocation[left + 1 ..< after].parseInt

          return (
              true,
              types.Location(path: maybeLocation[0 ..< left], line: line),
              cstring(maybeLocation),
              cstring(raw[after + 1 .. ^1]))
        except:
          discard

  return (false, l, cstring"", cstring"")

template appendBuild(self: BuildComponent, line: string, stdout: bool): untyped =
  let klass = if stdout: "build-stdout" else: "build-stderr"
  let (match, location, rawLocation, other) = self.matchLocation(line)
  if match:
    if rawLocation.len > 0:
      self.build.output.add((rawLocation, stdout))
    if other.len > 0:
      self.build.output.add((other, stdout))
    self.build.errors.add((location, rawLocation, other))
  else:
    if line.len > 0:
      self.build.output.add((cstring(line), stdout))

method onBuildCommand*(self: BuildComponent, response: BuildCommand) {.async.} =
  self.build.command = response.command
  self.data.redraw()

method onBuildStdout*(self: BuildComponent, response: BuildOutput) {.async.} =
  let lines = ($response.data).splitLines
  if self.build.output.len == 0:
    self.focusBuild()
  for line in lines:
    self.appendBuild(line, true)
  self.data.redraw()

method onBuildStderr*(self: BuildComponent, response: BuildOutput) {.async.} =
  let lines = ($response.data).splitLines
  if self.build.output.len == 0:
    self.focusBuild()
  for line in lines:
    self.appendBuild(line, false)
  self.data.redraw()

method onBuildCode*(self: BuildComponent, response: BuildCode) {.async.} =
  self.build.code = response.code
  self.build.running = false
  if self.build.code != 0:
    self.focusBuild()
    # Also focus the build errors tab via the component mapping,
    # instead of hard-coded GL tree indices that break with layout changes.
    if self.data.ui.componentMapping[Content.BuildErrors].len > 0:
      self.data.openLayoutTab(Content.BuildErrors)
    self.data.functions.switchToEdit(self.data)
  else:
    self.data.functions.switchToDebug(self.data)


proc buildLocationView(self: BuildComponent, location: types.Location, raw: cstring, klass: string): VNode =
  result = buildHtml(tdiv(class = &"build-location {klass}", onclick = proc =
      discard jumpLocation(location))):
    text raw

proc buildErrorView(self: BuildComponent, location: types.Location, rawLocation: cstring, other: cstring): VNode =
  result = buildHtml(tdiv(class = "build-error",
    onclick = proc = discard jumpLocation(location))):
      tdiv(class="build-location"):
        text rawLocation
      tdiv(class="build-other"):
        text other

method render*(self: BuildComponent): VNode =
  result = buildHtml(tdiv(class="build-panel")):
    if self.build.running:
      tdiv(class="build-header"):
        tdiv(class="build-command-label"):
          text "running " & self.build.command
    elif self.build.code != 0 and self.build.output.len > 0:
      tdiv(class="build-header build-failed"):
        tdiv(class="build-command-label"):
          text "build failed (exit code " & $self.build.code & ")"
    elif self.build.output.len > 0:
      tdiv(class="build-header build-succeeded"):
        tdiv(class="build-command-label"):
          text "build succeeded"
    tdiv(id="build", class="build-output-container"):
      for (raw, stdout) in self.build.output:
        let klass = if stdout: "build-stdout" else: "build-stderr"

        tdiv(class=klass):
          text raw

proc renderErrorsView*(self: BuildComponent): VNode =
  result = buildHtml(tdiv):
    tdiv(id="build-errors"):
      for (location, rawLocation, other) in self.build.errors:
        buildErrorView(self, location, rawLocation, other)
