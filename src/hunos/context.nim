## context.nim
##
## NimMax-style Context API for Hunos.
## Provides a convenient wrapper around Hunos Request/Response
## to ease migration from NimMax or similar frameworks.
##
## Usage:
##   import hunos/context
##
##   proc handler(request: Request) {.gcsafe.} =
##     let ctx = newContext(request)
##     let id = ctx.getInt("id")
##     if id.isSome:
##       ctx.json(%*{"id": id.get})
##     else:
##       ctx.text("Invalid ID", 400)

import ../hunos, std/options, std/json, std/strutils, std/tables
from ../hunos/sessions import getSession

export options, json

type
  Context* = ref object
    request*: Request
    response*: Response

proc newContext*(request: Request): Context =
  result = Context(
    request: request,
    response: Response(code: 200, headers: @[], body: "")
  )

# Typed parameter helpers
proc getPathParam*(ctx: Context, key: string): string =
  ctx.request.pathParams[key]

proc getQueryParam*(ctx: Context, key: string): string =
  for (k, v) in ctx.request.queryParams:
    if k == key:
      return v
  return ""

proc getInt*(ctx: Context, key: string, source = "path"): Option[int] =
  var val: string
  case source
  of "path": val = ctx.request.pathParams[key]
  of "query": val = ctx.getQueryParam(key)
  else: return none(int)
  try:
    result = some(parseInt(val))
  except ValueError:
    result = none(int)

proc getFloat*(ctx: Context, key: string, source = "path"): Option[float] =
  var val: string
  case source
  of "path": val = ctx.request.pathParams[key]
  of "query": val = ctx.getQueryParam(key)
  else: return none(float)
  try:
    result = some(parseFloat(val))
  except ValueError:
    result = none(float)

proc getBool*(ctx: Context, key: string, source = "query"): Option[bool] =
  var val: string
  case source
  of "path": val = ctx.request.pathParams[key]
  of "query": val = ctx.getQueryParam(key)
  else: return none(bool)
  let lower = val.toLowerAscii()
  if lower in ["true", "1", "yes", "on"]:
    result = some(true)
  elif lower in ["false", "0", "no", "off"]:
    result = some(false)
  else:
    result = none(bool)

# Session helpers
proc session*(ctx: Context): auto =
  ctx.request.getSession()

# Response helpers
proc respond*(ctx: Context, code: int = 200) =
  ctx.request.respond(code, ctx.response.headers, ctx.response.body)

proc html*(ctx: Context, body: string, code: int = 200) =
  ctx.response.code = code
  ctx.response.headers = @[("Content-Type", "text/html; charset=utf-8")]
  ctx.response.body = body
  ctx.request.respond(code, ctx.response.headers, body)

proc text*(ctx: Context, body: string, code: int = 200) =
  ctx.response.code = code
  ctx.response.headers = @[("Content-Type", "text/plain; charset=utf-8")]
  ctx.response.body = body
  ctx.request.respond(code, ctx.response.headers, body)

proc json*(ctx: Context, data: JsonNode, code: int = 200) =
  ctx.response.code = code
  ctx.response.headers = @[("Content-Type", "application/json; charset=utf-8")]
  ctx.response.body = $data
  ctx.request.respond(code, ctx.response.headers, ctx.response.body)

proc redirect*(ctx: Context, url: string, code: int = 302) =
  ctx.response.code = code
  ctx.response.headers = @[("Location", url)]
  ctx.request.respond(code, ctx.response.headers, "")

# Cookie helpers
proc getCookie*(ctx: Context, name: string): string =
  result = getCookie(ctx.request, name)

proc setCookie*(ctx: Context, name, value: string, path = "/",
                maxAge = 0, httpOnly = false, secure = false, sameSite = "Lax") =
  ctx.request.responseHeaders.setCookie(name, value, path, maxAge, httpOnly, secure, sameSite)

# Body helpers
proc getJsonBody*(ctx: Context): JsonNode =
  if ctx.request.body.len > 0:
    result = parseJson(ctx.request.body)
  else:
    result = newJObject()

proc getJsonBody*(ctx: Context, T: typedesc): T =
  if ctx.request.body.len > 0:
    result = parseJson(ctx.request.body).to(T)
  else:
    raise newException(ValueError, "Empty JSON body")
