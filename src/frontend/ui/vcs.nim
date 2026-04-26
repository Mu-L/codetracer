## VCS (Version Control System) panel component.
##
## A lazygit-style integrated version control panel shown as a Golden Layout
## component. Displays: branch picker, commit history, and changed files for
## the selected commit.
##
## In DeepReview mode (``data.deepReviewActive``), the panel switches to
## showing the review's changed files from ``data.deepReviewData.files``
## instead of git data.  Clicking a file updates
## ``data.deepReviewSelectedFileIndex`` which the DeepReview component reads
## to decide which file's diff to render.
##
## Git data is fetched by shelling out to `git` via Node.js `child_process`
## (available in Electron's renderer process with nodeIntegration enabled).

import
  ui_imports

# ---------------------------------------------------------------------------
# Node.js child_process bindings (renderer process, nodeIntegration=true)
# ---------------------------------------------------------------------------

type
  ExecSyncOptions = ref object
    cwd*: cstring
    encoding*: cstring
    timeout*: int

proc execSyncRaw(cmd: cstring, opts: ExecSyncOptions): cstring
  {.importjs: "require('child_process').execSync(#, #).toString()".}

proc gitExec(cmd: cstring, cwd: cstring): cstring =
  ## Run a git command in the given working directory.
  ## Returns the trimmed stdout output, or an empty string on error.
  try:
    let opts = ExecSyncOptions(cwd: cwd, encoding: cstring"utf8", timeout: 5000)
    let raw = execSyncRaw(cmd, opts)
    if raw.isNil:
      return cstring""
    # Trim trailing whitespace / newlines.
    return ($raw).strip().cstring
  except:
    return cstring""

proc isGitRepository(cwd: cstring): bool =
  ## Check whether `cwd` is inside a git working tree.
  let result_str = gitExec(cstring"git rev-parse --is-inside-work-tree", cwd)
  return result_str == cstring"true"

# ---------------------------------------------------------------------------
# Data loading helpers
# ---------------------------------------------------------------------------

proc loadCurrentBranch(self: VCSComponent, cwd: cstring) =
  self.currentBranch = gitExec(cstring"git branch --show-current", cwd)
  if self.currentBranch.len == 0:
    # Detached HEAD -- show abbreviated hash instead.
    self.currentBranch = gitExec(cstring"git rev-parse --short HEAD", cwd)

proc loadBranches(self: VCSComponent, cwd: cstring) =
  let raw = gitExec(cstring"git branch --format=%(refname:short)", cwd)
  self.branches = @[]
  if raw.len > 0:
    for line in ($raw).splitLines():
      let trimmed = line.strip()
      if trimmed.len > 0:
        self.branches.add(cstring(trimmed))

proc loadCommits(self: VCSComponent, cwd: cstring) =
  ## Load the 30 most recent commits with hash, subject and relative date.
  ## Uses ASCII record separator (0x1e) as delimiter to avoid conflicts with
  ## pipe characters that may appear in commit messages.
  const sep = "\x1e"
  let raw = gitExec(
    cstring("git log --pretty=format:%h" & sep & "%s" & sep & "%cr -30"), cwd)
  self.commits = @[]
  if raw.len > 0:
    for line in ($raw).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0:
        continue
      let parts = trimmed.split(sep)
      if parts.len >= 3:
        self.commits.add(VCSCommit(
          hash: cstring(parts[0]),
          message: cstring(parts[1]),
          relativeTime: cstring(parts[2])))
      elif parts.len == 2:
        self.commits.add(VCSCommit(
          hash: cstring(parts[0]),
          message: cstring(parts[1]),
          relativeTime: cstring""))
      elif parts.len == 1:
        self.commits.add(VCSCommit(
          hash: cstring(parts[0]),
          message: cstring"",
          relativeTime: cstring""))

proc loadChangedFiles(self: VCSComponent, cwd: cstring, commitHash: cstring) =
  ## Load the files changed in a specific commit with diff --stat style info.
  ## Uses `git diff-tree` which works for any commit without needing a parent
  ## check (root commits are handled with --root).
  let cmd = cstring("git diff-tree --no-commit-id -r --numstat " & $commitHash)
  let raw = gitExec(cmd, cwd)
  self.changedFiles = @[]
  if raw.len > 0:
    for line in ($raw).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0:
        continue
      # Format: <added>\t<deleted>\t<filename>
      let parts = trimmed.split("\t")
      if parts.len >= 3:
        var added = 0
        var deleted = 0
        try:
          added = parseInt(parts[0].strip())
        except ValueError:
          discard
        try:
          deleted = parseInt(parts[1].strip())
        except ValueError:
          discard
        # Determine status from the change pattern.
        let status = if added > 0 and deleted == 0: cstring"A"
                     elif added == 0 and deleted > 0: cstring"D"
                     else: cstring"M"
        self.changedFiles.add(VCSChangedFile(
          status: status,
          filename: cstring(parts[2]),
          additions: added,
          deletions: deleted))

  # If no numstat output, fall back to --name-status.
  if self.changedFiles.len == 0:
    let cmd2 = cstring("git diff-tree --no-commit-id -r --name-status " & $commitHash)
    let raw2 = gitExec(cmd2, cwd)
    if raw2.len > 0:
      for line in ($raw2).splitLines():
        let trimmed = line.strip()
        if trimmed.len == 0:
          continue
        let parts = trimmed.split("\t")
        if parts.len >= 2:
          self.changedFiles.add(VCSChangedFile(
            status: cstring(parts[0]),
            filename: cstring(parts[1]),
            additions: 0,
            deletions: 0))

proc getWorkingDirectory(self: VCSComponent): cstring =
  ## Determine the working directory for git commands.
  ## Prefers `startOptions.folder`, falling back to `process.cwd()`.
  let folder = self.data.startOptions.folder
  if not folder.isNil and folder.len > 0:
    return folder
  return electronProcess.cwd()

proc refreshVCSData*(self: VCSComponent) =
  ## Reload all VCS data from git.
  let cwd = self.getWorkingDirectory()
  if not isGitRepository(cwd):
    self.isGitRepo = false
    self.errorMessage = cstring"Not a git repository"
    return

  self.isGitRepo = true
  self.errorMessage = cstring""
  self.loadCurrentBranch(cwd)
  self.loadBranches(cwd)
  self.loadCommits(cwd)

  # If we have commits and a selection, load changed files.
  if self.commits.len > 0:
    if self.selectedCommitIndex < 0 or
       self.selectedCommitIndex >= self.commits.len:
      self.selectedCommitIndex = 0
    self.loadChangedFiles(cwd, self.commits[self.selectedCommitIndex].hash)

# ---------------------------------------------------------------------------
# DeepReview mode helpers
# ---------------------------------------------------------------------------

proc isDeepReviewMode(self: VCSComponent): bool =
  ## Return true when the VCS panel should show DeepReview changeset data
  ## instead of normal git data.
  self.data.deepReviewActive and not self.data.deepReviewData.isNil

proc renderDeepReviewHeader(self: VCSComponent): VNode =
  ## Render a header bar showing the review title or commit SHA in place of
  ## the branch picker.
  let drData = self.data.deepReviewData
  let hasTitle = not drData.sessionTitle.isNil and ($drData.sessionTitle).len > 0
  let commitDisplay = if drData.commitSha.len > 12:
    cstring(($drData.commitSha)[0 ..< 12] & "...")
  else:
    drData.commitSha

  buildHtml(tdiv(class = "vcs-branch-picker")):
    tdiv(class = "vcs-branch-current"):
      span(class = "vcs-branch-icon"):
        text "\xEF\x84\xA6" # git branch icon
      span(class = "vcs-branch-name"):
        if hasTitle:
          text drData.sessionTitle
        else:
          text cstring("Review: " & $commitDisplay)

proc makeDeepReviewFileClickHandler(self: VCSComponent, idx: int): proc(ev: Event, n: VNode) =
  ## Create a click handler for a file in the DeepReview file list.
  ## Uses a separate proc to avoid Nim JS backend closure-in-loop capture bug.
  let selfCapture = self
  result = proc(ev: Event, n: VNode) =
    selfCapture.data.deepReviewSelectedFileIndex = idx
    # Use redrawAll so the DeepReview component in the center panel also
    # picks up the new file index and re-renders its diff view.
    redrawAll()

proc renderDeepReviewChangedFiles(self: VCSComponent): VNode =
  ## Render the changed files list populated from DeepReview data.
  ## Each entry shows the diff status badge, file basename, full path,
  ## and line addition/removal counts.  Clicking a file updates
  ## ``data.deepReviewSelectedFileIndex`` so the DeepReview component
  ## shows that file's diff.
  let drData = self.data.deepReviewData
  buildHtml(tdiv(class = "vcs-changed-files")):
    tdiv(class = "vcs-section-header"):
      text "Changed Files"
      span(class = "vcs-changed-files-commit"):
        text cstring(" (" & $drData.files.len & " files)")

    tdiv(class = "vcs-file-list"):
      if drData.files.len == 0:
        tdiv(class = "vcs-no-files"):
          text "No changed files"
      else:
        for i, file in drData.files:
          let isSelected = (i == self.data.deepReviewSelectedFileIndex)
          let selectedClass = if isSelected: " vcs-file-selected" else: ""

          # Determine status from diff data.
          let status = if not file.diff.isNil and ($file.diff.status).len > 0:
            file.diff.status
          else:
            cstring"M"
          let statusClass = case $status
            of "A": "vcs-status-added"
            of "D": "vcs-status-deleted"
            of "M": "vcs-status-modified"
            else: "vcs-status-other"

          tdiv(class = cstring("vcs-file-item" & selectedClass),
               onclick = self.makeDeepReviewFileClickHandler(i)):
            span(class = cstring("vcs-file-status " & statusClass)):
              text status
            span(class = "vcs-file-name"):
              # Show just the basename for compact display.
              let pathStr = $file.path
              let slashIdx = pathStr.rfind('/')
              let baseName = if slashIdx >= 0: pathStr[slashIdx + 1 .. ^1] else: pathStr
              text cstring(baseName)
            if not file.diff.isNil and (file.diff.linesAdded > 0 or file.diff.linesRemoved > 0):
              span(class = "vcs-file-stats"):
                if file.diff.linesAdded > 0:
                  span(class = "vcs-stat-added"):
                    text cstring("+" & $file.diff.linesAdded)
                if file.diff.linesRemoved > 0:
                  span(class = "vcs-stat-deleted"):
                    text cstring("-" & $file.diff.linesRemoved)
            # Coverage badge: show executed/total line count.
            if file.coverage.len > 0:
              var executed = 0
              for cov in file.coverage:
                if cov.executed:
                  executed += 1
              span(class = "vcs-file-coverage"):
                text cstring(fmt"{executed}/{file.coverage.len}")

# ---------------------------------------------------------------------------
# Normal git mode render helpers
# ---------------------------------------------------------------------------

proc renderBranchPicker(self: VCSComponent): VNode =
  buildHtml(tdiv(class = "vcs-branch-picker")):
    tdiv(class = "vcs-branch-current",
         onclick = proc(ev: Event, tg: VNode) =
           self.branchDropdownOpen = not self.branchDropdownOpen
           data.redraw()):
      span(class = "vcs-branch-icon"):
        text "\xEF\x84\xA6" # git branch unicode icon fallback
      span(class = "vcs-branch-name"):
        text self.currentBranch
      span(class = "vcs-branch-arrow"):
        if self.branchDropdownOpen:
          text "\xE2\x96\xB2" # up triangle
        else:
          text "\xE2\x96\xBC" # down triangle

    if self.branchDropdownOpen:
      tdiv(class = "vcs-branch-dropdown"):
        for branch in self.branches:
          let branchCopy = branch
          tdiv(class = "vcs-branch-option",
               onclick = proc(ev: Event, tg: VNode) =
                 self.branchDropdownOpen = false
                 # Checkout branch via git.
                 let cwd = self.getWorkingDirectory()
                 discard gitExec(cstring("git checkout " & $branchCopy), cwd)
                 self.refreshVCSData()
                 data.redraw()):
            let isActive = branch == self.currentBranch
            if isActive:
              span(class = "vcs-branch-active-marker"):
                text "* "
            text branch

proc renderCommitHistory(self: VCSComponent): VNode =
  buildHtml(tdiv(class = "vcs-commit-history")):
    tdiv(class = "vcs-section-header"):
      text "Commits"
    tdiv(class = "vcs-commit-list"):
      for i, commit in self.commits:
        let index = i
        let isSelected = index == self.selectedCommitIndex
        let selectedClass = if isSelected: " vcs-commit-selected" else: ""
        tdiv(class = cstring("vcs-commit-item" & selectedClass),
             onclick = proc(ev: Event, tg: VNode) =
               self.selectedCommitIndex = index
               let cwd = self.getWorkingDirectory()
               self.loadChangedFiles(cwd, self.commits[index].hash)
               data.redraw()):
          span(class = "vcs-commit-hash"):
            text commit.hash
          span(class = "vcs-commit-message"):
            text commit.message
          span(class = "vcs-commit-time"):
            text commit.relativeTime

proc renderChangedFiles(self: VCSComponent): VNode =
  buildHtml(tdiv(class = "vcs-changed-files")):
    tdiv(class = "vcs-section-header"):
      text "Changed Files"
      if self.selectedCommitIndex >= 0 and
         self.selectedCommitIndex < self.commits.len:
        span(class = "vcs-changed-files-commit"):
          text " (" & self.commits[self.selectedCommitIndex].hash & ")"

    tdiv(class = "vcs-file-list"):
      if self.changedFiles.len == 0:
        tdiv(class = "vcs-no-files"):
          text "No changed files"
      else:
        for file in self.changedFiles:
          let filePath = file.filename
          let statusClass = case $file.status
            of "A": "vcs-status-added"
            of "D": "vcs-status-deleted"
            of "M": "vcs-status-modified"
            else: "vcs-status-other"
          tdiv(class = "vcs-file-item",
               onclick = proc(ev: Event, tg: VNode) =
                 data.openTab(filePath, ViewSource)):
            span(class = cstring("vcs-file-status " & statusClass)):
              text file.status
            span(class = "vcs-file-name"):
              # Show just the basename for compact display.
              let pathStr = $filePath
              let slashIdx = pathStr.rfind('/')
              let baseName = if slashIdx >= 0: pathStr[slashIdx + 1 .. ^1] else: pathStr
              text cstring(baseName)
            if file.additions > 0 or file.deletions > 0:
              span(class = "vcs-file-stats"):
                if file.additions > 0:
                  span(class = "vcs-stat-added"):
                    text cstring("+" & $file.additions)
                if file.deletions > 0:
                  span(class = "vcs-stat-deleted"):
                    text cstring("-" & $file.deletions)

method render*(self: VCSComponent): VNode =
  # In DeepReview mode, show the review's changed files instead of git data.
  if self.isDeepReviewMode():
    return buildHtml(tdiv(class = componentContainerClass("vcs-container"))):
      renderDeepReviewHeader(self)
      renderDeepReviewChangedFiles(self)

  # Normal git mode: lazy initialization on first render.
  if not self.initialized:
    self.initialized = true
    self.refreshVCSData()

  buildHtml(tdiv(class = componentContainerClass("vcs-container"))):
    if not self.isGitRepo:
      tdiv(class = "vcs-no-repo"):
        tdiv(class = "vcs-no-repo-icon"):
          text "\xEF\x84\xA6" # git icon
        tdiv(class = "vcs-no-repo-message"):
          text self.errorMessage
    else:
      renderBranchPicker(self)
      renderCommitHistory(self)
      renderChangedFiles(self)
      tdiv(class = "vcs-refresh",
           onclick = proc(ev: Event, tg: VNode) =
             self.refreshVCSData()
             data.redraw()):
        text "Refresh"
