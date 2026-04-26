## BP-M4: Problems panel -- a structured, filterable list of build errors
## and warnings, similar to the Problems panel in VS Code.
##
## The panel reads from `self.data.buildComponent(0).build.problems` which
## is populated by the build component as it parses build output lines.
## Each problem carries severity, file path, line:col, and message.
##
## Features:
## - Click-to-navigate: clicking a problem opens the file at the error location
## - Filter by severity (All / Errors only / Warnings only)
## - Group by file (optional toggle)
## - Problem count displayed in the panel header

import
  ui_imports, ../types

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc problemCount(problems: seq[BuildProblem], severity: ProblemSeverity): int =
  ## Count problems matching a specific severity.
  for p in problems:
    if p.severity == severity:
      inc result

proc filterProblems(problems: seq[BuildProblem], filter: ProblemFilter): seq[BuildProblem] =
  ## Return only the problems matching the active filter.
  case filter
  of FilterAll:
    return problems
  of FilterErrors:
    for p in problems:
      if p.severity == ProbError:
        result.add(p)
  of FilterWarnings:
    for p in problems:
      if p.severity == ProbWarning:
        result.add(p)

proc severityClass(severity: ProblemSeverity): string =
  ## CSS class suffix for the severity icon/row.
  case severity
  of ProbError:   "error"
  of ProbWarning: "warning"
  of ProbInfo:    "info"

proc severityIcon(severity: ProblemSeverity): string =
  ## Unicode character used as a severity indicator.
  ## Error = filled circle, Warning = triangle, Info = info circle.
  case severity
  of ProbError:   "\xe2\x97\x8f"   # U+25CF BLACK CIRCLE
  of ProbWarning: "\xe2\x9a\xa0"   # U+26A0 WARNING SIGN
  of ProbInfo:    "\xe2\x93\x98"   # U+24D8 CIRCLED LATIN SMALL LETTER I

proc locationText(p: BuildProblem): string =
  ## Format "line:col" or just "line" when col is unknown.
  if p.col >= 0:
    $p.line & ":" & $p.col
  else:
    $p.line

# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------

proc renderProblemRow(self: ErrorsComponent, p: BuildProblem): VNode =
  ## Render a single problem row.  Clicking the row navigates the editor
  ## to the problem's source location.
  let loc = types.Location(path: p.path, line: p.line)
  let sevClass = severityClass(p.severity)

  result = buildHtml(tdiv(
    class = "problems-row problems-severity-" & sevClass,
    onclick = proc = discard jumpLocation(loc)
  )):
    tdiv(class = "problems-icon problems-icon-" & sevClass):
      text severityIcon(p.severity)
    tdiv(class = "problems-path"):
      text $p.path
    tdiv(class = "problems-location"):
      text locationText(p)
    tdiv(class = "problems-message"):
      text $p.message

type
  FileGroup = object
    ## Helper for grouping problems by file path.
    path: cstring
    items: seq[BuildProblem]

proc groupByFilePath(problems: seq[BuildProblem]): seq[FileGroup] =
  ## Group a flat list of problems into per-file groups, preserving the
  ## order in which each file first appears.
  for p in problems:
    var found = false
    for g in result.mitems:
      if g.path == p.path:
        g.items.add(p)
        found = true
        break
    if not found:
      result.add(FileGroup(path: p.path, items: @[p]))

proc renderGroupedByFile(self: ErrorsComponent, problems: seq[BuildProblem]): VNode =
  ## Render problems grouped under file-path headers.
  let groups = groupByFilePath(problems)

  result = buildHtml(tdiv(class = "problems-grouped")):
    for group in groups:
      tdiv(class = "problems-file-group"):
        tdiv(class = "problems-file-header"):
          text $group.path & " (" & $group.items.len & ")"
        for p in group.items:
          renderProblemRow(self, p)

# ---------------------------------------------------------------------------
# Main render
# ---------------------------------------------------------------------------

method render*(self: ErrorsComponent): VNode =
  ## Render the full Problems panel with header (counts + filter controls)
  ## and the problem list below.
  let buildComp = self.data.buildComponent(0)
  let allProblems = buildComp.build.problems
  let errorCount = problemCount(allProblems, ProbError)
  let warningCount = problemCount(allProblems, ProbWarning)
  let visible = filterProblems(allProblems, self.filter)

  result = buildHtml(tdiv(class = "problems-panel")):
    # -- Header bar: counts and controls --
    tdiv(class = "problems-header"):
      tdiv(class = "problems-counts"):
        tdiv(class = "problems-count-badge problems-count-error"):
          text severityIcon(ProbError) & " " & $errorCount
        tdiv(class = "problems-count-badge problems-count-warning"):
          text severityIcon(ProbWarning) & " " & $warningCount
        tdiv(class = "problems-count-badge"):
          text "Total: " & $allProblems.len

      tdiv(class = "problems-controls"):
        # Filter buttons
        tdiv(
          class = "problems-filter-btn" & (if self.filter == FilterAll: " active" else: ""),
          onclick = proc =
            self.filter = FilterAll
            self.data.redraw()
        ):
          text "All"
        tdiv(
          class = "problems-filter-btn" & (if self.filter == FilterErrors: " active" else: ""),
          onclick = proc =
            self.filter = FilterErrors
            self.data.redraw()
        ):
          text "Errors"
        tdiv(
          class = "problems-filter-btn" & (if self.filter == FilterWarnings: " active" else: ""),
          onclick = proc =
            self.filter = FilterWarnings
            self.data.redraw()
        ):
          text "Warnings"

        # Group-by-file toggle
        tdiv(
          class = "problems-filter-btn" & (if self.groupByFile: " active" else: ""),
          onclick = proc =
            self.groupByFile = not self.groupByFile
            self.data.redraw()
        ):
          text "Group by File"

    # -- Problem list --
    tdiv(id = "problems-list", class = "problems-list"):
      if visible.len == 0:
        tdiv(class = "problems-empty"):
          text "No problems detected."
      elif self.groupByFile:
        renderGroupedByFile(self, visible)
      else:
        for p in visible:
          renderProblemRow(self, p)
