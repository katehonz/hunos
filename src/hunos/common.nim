import std/typetraits, std/options, std/strutils

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

proc getInt*(pathParams: PathParams, key: string): Option[int] =
  try:
    result = some(parseInt(pathParams[key]))
  except ValueError:
    result = none(int)

proc getFloat*(pathParams: PathParams, key: string): Option[float] =
  try:
    result = some(parseFloat(pathParams[key]))
  except ValueError:
    result = none(float)

proc getBool*(pathParams: PathParams, key: string): Option[bool] =
  let val = pathParams[key].toLowerAscii()
  if val == "true" or val == "1" or val == "yes" or val == "on":
    result = some(true)
  elif val == "false" or val == "0" or val == "no" or val == "off":
    result = some(false)
  else:
    result = none(bool)

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
