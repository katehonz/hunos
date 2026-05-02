import ../hunos, std/atomics, std/strutils, std/times

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
