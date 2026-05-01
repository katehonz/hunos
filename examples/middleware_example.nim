import hunos, hunos/router, hunos/middleware

proc indexHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  request.respond(200, headers, """
  <!DOCTYPE html>
  <html>
  <head><title>Hunos Middleware Example</title></head>
  <body>
    <h1>Hunos with Middleware</h1>
    <p>This server uses CORS, logging, and request ID middleware.</p>
    <p>Check the response headers to see CORS and request ID headers.</p>
  </body>
  </html>
  """)

proc apiHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"message": "Hello from API", "status": "ok"}""")

var router: Router
router.get("/", indexHandler)
router.get("/api", apiHandler)

var stack = newMiddlewareStack(router)
stack.use(corsMiddleware())
stack.use(loggingMiddleware())
stack.use(requestIdMiddleware())
stack.use(recoveryMiddleware())

let server = newServer(stack)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
