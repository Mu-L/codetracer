import
  std/[strutils, strformat, sequtils, algorithm, rdstdin],
  ../../common/[ trace_index, types, lang ],
  ../launch/cleanup,
  ../utilities/env,
  ../codetracerconf,
  json_serialization

const
  TRACE_CMD_COLUMN_WIDTH = 70
  TRACE_WORKDIR_COLUMN_WIDTH = 40

func limitColumnLeft(text: string, width: int): string =
  if text.len > width:
    ".." & text[text.len - (width - 2) .. ^1]
  else:
    text


func limitColumnRight(text: string, width: int): string =
  if text.len > width:
    text[0 .. (width - 2) - 1] & ".."
  else:
    text


func traceInText*(trace: Trace): string =
  let displayCmd = limitColumnRight(trace.program & " " & trace.args.join(" "), TRACE_CMD_COLUMN_WIDTH)
  let displayWorkdir = limitColumnLeft("ran in " & trace.workdir, TRACE_WORKDIR_COLUMN_WIDTH)
  let idColumn = fmt"{trace.id}."
  alignLeft(idColumn, 5) & " | " & alignLeft(displayCmd, TRACE_CMD_COLUMN_WIDTH) & " | " &
  alignLeft(displayWorkdir, TRACE_WORKDIR_COLUMN_WIDTH) & " | " &
  alignLeft(toName(trace.lang), 15) & " | " & alignLeft(trace.date, 15)


func tracesInText*(traces: seq[Trace]): string =
  traces.reversed.mapIt(traceInText(it)).join("\n")


func tracesInJson*(traces: seq[Trace]): string =
  Json.encode(traces)


proc interactiveTraceSelectMenu*(command: StartupCommand): Trace =
  let recordCore = envLoadRecordCore()
  let action = if command == StartupCommand.upload: "upload" else: "replay"
  # ordered by id
  # returns the newest(biggest id) first
  let traces = trace_index.all(test=false)
  let limitedTraces = if traces.len > 10:
      traces[0 ..< 10]
    else:
      traces

  echo &"Select a trace to {action}, entering its id:"
  echo ""

  for trace in limitedTraces:
    echo traceInText(trace)

  if traces.len > 10:
    echo "..(older traces not shown)"

  echo ""

  while true:
    var raw: string = ""
    try:
      raw = readLineFromStdin(&"{action}: ")
    except:
      echo "Interrupt detected. Exiting!"
      cleanup()
      quit(0)

    try:
      let traceId = raw.parseInt
      let trace = trace_index.find(traceId, test=false)
      if not trace.isNil:
        return trace
      else:
        echo fmt"trace with id {traceId} not found in local codetracer db, please try again"
    except:
      echo "error: ", getCurrentExceptionMsg()
      echo "please try again"
