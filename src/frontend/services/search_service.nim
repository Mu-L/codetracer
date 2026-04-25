import
  service_imports,
  ../ui/auto_hide

#data.services.search.pluginCommands = rendererPluginCommands

proc input*(self: SearchService, query: cstring) {.async.} =
  discard

proc run*(self: SearchService) {.async.} =
  discard

# proc parseSearch*(self: SearchService, query: cstring, includePattern: cstring, excludePattern: cstring): SearchQuery =
#   let tokens = ($query).split(" ", 1)
#   var command = cstring"text"
#   var searchQuery = query
#   if tokens.len > 0 and self.pluginCommands.hasKey(cstring(tokens[0])):
#     command = cstring(tokens[0])
#     searchQuery = cstring(tokens[1])

#   SearchQuery(command: command, query: searchQuery, includePattern: includePattern, excludePattern: excludePattern)

proc run*(self: SearchService, query: cstring, includePattern: cstring, excludePattern: cstring) {.async.} =
  if query.len == 0:
    echo "no search for empty query"
    return
  # let searchQuery = self.parseSearch(query, includePattern, excludePattern)
  # #self.services.search.parseQuery(value, cstring"", cstring"")
  # self.results[searchQuery.searchMode] = @[]
  # self.active[searchQuery.searchMode] = true
  # self.query = searchQuery
  # self.data.ipc.send "CODETRACER::search", searchQuery #, "", seq[CommandResult], noCache=true)
  # self.data.redraw()

proc searchProgram*(self: SearchService, query: cstring) =
  clog "searchProgram in service " & $query
  self.data.ipc.send("CODETRACER::search-program", query)

data.services.search.onSearchResultsUpdated = proc(self: SearchService, results: seq[SearchResult]) {.async.} =
  self.results[self.query.searchMode] = self.results[self.query.searchMode].concat(results)
  self.active[self.query.searchMode] = true
  self.data.ui.status.searchResults.active = true
  # Auto-reveal the search results panel if it is pinned to an auto-hide edge.
  if not autoHideState.isNil:
    let panel = autoHideState.findPanelByContent(Content.SearchResults)
    if not panel.isNil:
      showOverlay(panel)
  self.data.redraw()

proc restart*(service: SearchService) =
  discard
