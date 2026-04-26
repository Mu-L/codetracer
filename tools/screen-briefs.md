# Per-Screen Design Briefs

Each section describes exactly what should be visible in the screenshot and how it should look.

## Screen 1: Normal Layout (full-width, trace loaded)
**Expected**: Full CodeTracer window with panels filling the entire width. No gray areas.
- Top toolbar: debugger controls (step, continue, etc.)
- Left: FILESYSTEM panel with file tree showing test program files
- Center-top: Editor tab with Python source code, line numbers, syntax highlighting
- Right-top: STATE/SCRATCHPAD tabs and CALLTRACE/AGENT ACTIVITY tabs
- Bottom: EVENT LOG (active) and TERMINAL OUTPUT tabs with event data visible
- Status bar at very bottom: language indicator, encoding, stable/busy, file path
- **NO session tab bar** when only 1 trace loaded
- **NO gray empty areas** — panels fill edge to edge

## Screen 2: BUILD Panel (happy path — successful build)
**Expected**: Bottom panel area showing BUILD tab active with build output.
- BUILD tab header showing "Build succeeded" in green
- Build output lines with syntax-colored text (ANSI colors rendered)
- Header controls visible: stop button (disabled), clear button, auto-scroll toggle, duration
- Lines scrollable, monospace font matching editor
- No raw ANSI escape characters visible — all converted to colored HTML

## Screen 3: BUILD Panel (unhappy path — failed build with errors)
**Expected**: BUILD tab showing error output from a failed compilation.
- BUILD tab header showing "Build failed (exit code 1)" in red
- Error lines highlighted in red (#f85149) with clickable styling
- Warning lines in yellow (#d29922)
- Parsed file:line:col locations underlined and clickable
- ANSI-colored compiler output (e.g., cargo's colored errors)

## Screen 4: PROBLEMS Panel with parsed errors
**Expected**: PROBLEMS tab active showing structured error list.
- Header with error/warning counts
- Filter buttons: All / Errors / Warnings
- Error rows: red severity icon, file path, line:col, error message
- Warning rows: yellow severity icon
- Rows clickable (cursor: pointer on hover)
- Group-by-file headers when multiple files have errors

## Screen 5: SEARCH RESULTS with results
**Expected**: SEARCH RESULTS tab active with search matches.
- Header showing result count and search query
- Results grouped by file with file path headers
- Each match: line number + text with search term highlighted (yellow/amber)
- Clickable rows for navigation

## Screen 6: Auto-hide — left strip with FILESYSTEM, overlay open
**Expected**: Left strip tiled beside GL (not overlaying).
- Thin vertical strip (~28px) on the left edge with vertical text label "FILESYSTEM"
- GL panels start immediately after the strip (no overlap, no gray area)
- Overlay panel slides in from left showing the FILESYSTEM file tree
- Overlay has "Unpin" button at top-right
- Overlay content is the LIVE file tree (not a placeholder)

## Screen 7: Auto-hide — bottom tab in status bar, overlay open
**Expected**: Status bar has auto-hide tab labels in the center area.
- Bottom auto-hide label visible between left and right status bar items
- Overlay slides up from bottom showing the pinned panel's content
- Overlay flush with bottom edge (no gap)
- Full width overlay

## Screen 8: Multi-tab mode — two traces loaded
**Expected**: Session tab bar visible above GL when 2+ traces loaded.
- Tab bar shows 2 tabs (one per trace) with program names
- Active tab highlighted
- "+" button to add new trace
- GL layout below shows the active trace's panels
- All panels show data from the active trace (not mixed)

## Screen 9: DeepReview — standard layout with changed files
**Expected**: Standard CodeTracer layout with DeepReview data.
- FILESYSTEM panel showing changed files with diff badges (A/M/D colors)
- File paths, modified line counts (+N/-M)
- Editor area (may be empty if no trace data available)
- All standard panels present (STATE, CALLTRACE, EVENT LOG, etc.)

## Evaluation criteria (all screens)
- Dark theme: #1e1e1e background, #252526 panels, #3c3c3c borders
- Panels fill full window width — NO gray empty areas
- Consistent fonts (monospace for code, sans-serif for UI)
- Professional IDE-quality appearance
- Rating: 1-3 broken, 4-5 rough, 6-7 good, 8-9 near-shipping, 10 perfect
