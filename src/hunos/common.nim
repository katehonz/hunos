import std/typetraits

type
  HunosError* = object of CatchableError

  HttpVersion* = enum
    Http10, Http11

  LogLevel* = enum
    DebugLevel, InfoLevel, WarnLevel, ErrorLevel

  LogHandler* = proc(level: LogLevel, args: varargs[string]) {.gcsafe.}

  PathParams* = distinct seq[(string, string)]

converter toBase*(pathParams: var PathParams): var seq[(string, string)] =
  pathParams.distinctBase

converter toBase*(pathParams: PathParams): lent seq[(string, string)] =
  pathParams.distinctBase

proc `[]`*(pathParams: PathParams, key: string): string =
  for (k, v) in pathParams.toBase:
    if k == key:
      return v

proc `[]=`*(pathParams: var PathParams, key, value: string) =
  for pair in pathParams.mitems:
    if pair[0] == key:
      pair[1] = value
      return
  pathParams.add((key, value))

proc contains*(pathParams: PathParams, key: string): bool =
  for pair in pathParams:
    if pair[0] == key:
      return true

proc getOrDefault*(pathParams: PathParams, key, default: string): string =
  if key in pathParams: pathParams[key] else: default

proc echoLogger*(level: LogLevel, args: varargs[string]) =
  if args.len == 1:
    echo args[0]
  else:
    var lineLen = 0
    for arg in args:
      lineLen += arg.len
    var line = newStringOfCap(lineLen)
    for arg in args:
      line.add(arg)
    echo line
