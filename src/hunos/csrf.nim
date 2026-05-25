## csrf.nim
##
## CSRF protection middleware for Hunos.
## Works together with the sessions module.
##
## Usage:
##   import hunos/csrf, hunos/sessions
##
##   var stack = newMiddlewareStack(handler)
##   stack.use(sessionMiddleware(store))
##   stack.use(csrfMiddleware())
##
## In handlers:
##   proc formHandler(request: Request) {.gcsafe.} =
##     let token = request.getCsrfToken()
##     let html = "<form><input type=\"hidden\" name=\"csrf_token\" value=\"" & token & "\"></form>"
##     request.respond(200, body = html)

import ../hunos, ../hunos/middleware, ../hunos/sessions, std/strutils, std/random, std/sets, std/sysrand

const
  csrfTokenKey = "_csrf_token"
  csrfTokenLength = 32

proc generateCsrfToken*(): string =
  var bytes = newSeq[byte](csrfTokenLength)
  getRandomBytes(bytes)
  const hexChars = "0123456789abcdef"
  result = newString(csrfTokenLength * 2)
  for i in 0 ..< csrfTokenLength:
    result[i * 2]     = hexChars[(bytes[i] shr 4) and 0x0F]
    result[i * 2 + 1] = hexChars[bytes[i] and 0x0F]

proc getCsrfToken*(request: Request): string =
  let sess = request.getSession()
  if sess == nil:
    return ""
  var token = sess.get(csrfTokenKey)
  if token.len == 0:
    token = generateCsrfToken()
    sess.set(csrfTokenKey, token)
  result = token

proc csrfTokenInput*(request: Request): string =
  let token = request.getCsrfToken()
  result = "<input type=\"hidden\" name=\"csrf_token\" value=\"" & token & "\">"

proc getPostParam(request: Request, key: string): string =
  ## Simple helper to extract a form field from request body.
  ## Expects URL-encoded body like: csrf_token=abc123&name=value
  let body = request.body
  let prefix = key & "="
  var i = body.find(prefix)
  if i == -1:
    return ""
  i += prefix.len
  var j = i
  while j < body.len and body[j] notin {'&', '\r', '\n'}:
    inc j
  result = body[i ..< j]

proc csrfMiddleware*(
  tokenHeader: string = "X-CSRF-Token",
  tokenField: string = "csrf_token",
  safeMethods: HashSet[string] = toHashSet(["GET", "HEAD", "OPTIONS", "TRACE"])
): MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    let methodStr = request.httpMethod

    if methodStr in safeMethods:
      # Ensure a token exists for future unsafe requests
      discard request.getCsrfToken()
      next()
      return

    # State-changing request: validate token
    let sess = request.getSession()
    if sess == nil:
      request.respond(403, body = "CSRF protection requires session")
      return

    let expectedToken = sess.get(csrfTokenKey)
    if expectedToken.len == 0:
      request.respond(403, body = "CSRF token missing from session")
      return

    var providedToken = request.headers[tokenHeader]
    if providedToken.len == 0:
      providedToken = getPostParam(request, tokenField)

    if providedToken.len == 0:
      request.respond(403, body = "CSRF token missing from request")
      return

    if providedToken != expectedToken:
      request.respond(403, body = "CSRF token mismatch")
      return

    next()
