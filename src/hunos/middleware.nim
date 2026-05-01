import ../hunos, std/tables, std/times, std/strutils

type
  MiddlewareProc* = proc(request: Request, next: proc()) {.gcsafe.}

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
  return proc(request: Request, next: proc()) {.gcsafe.} =
    request.headers["Access-Control-Allow-Origin"] = allowOrigin
    request.headers["Access-Control-Allow-Methods"] = allowMethods
    request.headers["Access-Control-Allow-Headers"] = allowHeaders
    request.headers["Access-Control-Max-Age"] = maxAge

    if request.httpMethod == "OPTIONS":
      request.respond(204)
      return

    next()

proc loggingMiddleware*(
  logHandler: proc(msg: string) {.gcsafe.} = nil
): MiddlewareProc =
  return proc(request: Request, next: proc()) {.gcsafe.} =
    let startTime = epochTime()

    next()

    let duration = epochTime() - startTime
    let msg = request.httpMethod & " " & request.uri & " " &
              $duration & "s"

    if logHandler != nil:
      logHandler(msg)

proc requestIdMiddleware*: MiddlewareProc =
  return proc(request: Request, next: proc()) {.gcsafe.} =
    let existingId = request.headers["X-Request-Id"]
    if existingId == "":
      request.headers["X-Request-Id"] = $cast[uint64](request)
    next()

proc recoveryMiddleware*(
  errorHandler: proc(request: Request, e: ref Exception) {.gcsafe.} = nil
): MiddlewareProc =
  return proc(request: Request, next: proc()) {.gcsafe.} =
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
