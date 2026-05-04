import ../hunos, std/atomics, std/strutils, std/times, std/json, std/base64

var requestIdCounter*: Atomic[uint64]

type
  MiddlewareProc* = proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.}

  MiddlewareStack* = object
    middlewares: seq[MiddlewareProc]
    handler: RequestHandler

proc newMiddlewareStack*(handler: RequestHandler): MiddlewareStack =
  result.handler = handler
  result.middlewares = @[]

proc use*(stack: var MiddlewareStack, middleware: MiddlewareProc) =
  stack.middlewares.add(middleware)

proc toHandler*(stack: MiddlewareStack): RequestHandler =
  let handler = stack.handler
  let middlewares = stack.middlewares

  return proc(request: Request) =
    var idx = 0

    proc next() {.gcsafe.} =
      if idx < middlewares.len:
        let current = middlewares[idx]
        inc idx
        current(request, next)
      else:
        handler(request)

    next()

converter convertToHandler*(stack: MiddlewareStack): RequestHandler =
  stack.toHandler()

proc corsMiddleware*(
  allowOrigin: string = "*",
  allowMethods: string = "GET, POST, PUT, DELETE, OPTIONS, PATCH",
  allowHeaders: string = "Content-Type, Authorization",
  maxAge: string = "86400"
): MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    request.responseHeaders["Access-Control-Allow-Origin"] = allowOrigin
    request.responseHeaders["Access-Control-Allow-Methods"] = allowMethods
    request.responseHeaders["Access-Control-Allow-Headers"] = allowHeaders
    request.responseHeaders["Access-Control-Max-Age"] = maxAge

    if request.httpMethod == "OPTIONS":
      request.respond(204)
      return

    next()

proc loggingMiddleware*(
  logHandler: proc(msg: string) {.gcsafe.} = nil
): MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    let startTime = epochTime()

    next()

    let duration = epochTime() - startTime
    let msg = request.httpMethod & " " & request.uri & " " &
              formatFloat(duration, ffDecimal, 4) & "s"

    if duration > 1.0:
      if logHandler != nil:
        logHandler("[SLOW] " & msg)
      else:
        request.log(WarnLevel, "Slow request: ", msg)
    elif logHandler != nil:
      logHandler(msg)
    else:
      request.log(InfoLevel, msg)

proc requestIdMiddleware*: MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    let existingId = request.headers["X-Request-Id"]
    if existingId != "":
      request.responseHeaders["X-Request-Id"] = existingId
    else:
      let id = requestIdCounter.fetchAdd(1)
      let idStr = $id
      request.headers["X-Request-Id"] = idStr
      request.responseHeaders["X-Request-Id"] = idStr
    next()

proc recoveryMiddleware*(
  errorHandler: proc(request: Request, e: ref Exception) {.gcsafe.} = nil
): MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    try:
      next()
    except Exception as e:
      if errorHandler != nil:
        errorHandler(request, e)
      else:
        if not request.responded:
          var headers: HttpHeaders
          headers["Content-Type"] = "text/plain"
          request.respond(500, headers, "Internal Server Error")

proc jsonBodyMiddleware*: MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    let ct = request.headers["Content-Type"]
    if ct.startsWith("application/json") and request.body.len > 0:
      try:
        discard parseJson(request.body)
      except JsonParsingError:
        request.respond(400, body = "Invalid JSON")
        return
    next()

proc getJsonBody*(request: Request): JsonNode =
  if request.body.len > 0:
    return parseJson(request.body)
  else:
    return newJObject()

type
  VerifyHandler* = proc(username, password: string): bool {.gcsafe.}

proc basicAuthMiddleware*(
  realm: string,
  verifyHandler: VerifyHandler
): MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    let authHeader = request.headers["Authorization"]
    if authHeader.len == 0 or not authHeader.startsWith("Basic "):
      var headers: HttpHeaders
      headers["WWW-Authenticate"] = "Basic realm=\"" & realm & "\""
      request.respond(401, headers, "Authentication required")
      return

    let encoded = authHeader[6 .. ^1]
    let decoded = decode(encoded)
    let colonPos = decoded.find(':')
    if colonPos == -1:
      var headers: HttpHeaders
      headers["WWW-Authenticate"] = "Basic realm=\"" & realm & "\""
      request.respond(401, headers, "Invalid credentials")
      return

    let username = decoded[0 ..< colonPos]
    let password = decoded[colonPos + 1 .. ^1]

    if not verifyHandler(username, password):
      var headers: HttpHeaders
      headers["WWW-Authenticate"] = "Basic realm=\"" & realm & "\""
      request.respond(401, headers, "Invalid credentials")
      return

    next()
