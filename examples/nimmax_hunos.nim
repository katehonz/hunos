## NimMax-style Hunos Example
##
## Demonstrates how to use Hunos with a NimMax-like Context API.
## This example shows routing, typed path params, JSON responses,
## sessions, flash messages, form validation, and CSRF protection.

import hunos, hunos/router, hunos/middleware
import hunos/context, hunos/sessions, hunos/csrf
import std/json, std/options

proc indexHandler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  ctx.html("""
  <!DOCTYPE html>
  <html>
  <head><title>NimMax on Hunos</title></head>
  <body>
    <h1>Welcome to NimMax on Hunos!</h1>
    <p>This server uses NimMax-style Context API on top of Hunos multi-threaded architecture.</p>
    <ul>
      <li><a href="/user/42">Typed params: /user/42</a></li>
      <li><a href="/api/data">JSON API: /api/data</a></li>
      <li><a href="/flash">Flash messages</a></li>
    </ul>
  </body>
  </html>
  """)

proc userHandler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  let id = ctx.getInt("id")
  if id.isSome:
    ctx.json(%*{"userId": id.get, "message": "Found user"})
  else:
    ctx.json(%*{"error": "Invalid user ID"}, 400)

proc apiHandler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  ctx.json(%*{
    "framework": "NimMax on Hunos",
    "features": [
      "Trie router (O(k) matching)",
      "Multi-threaded workers",
      "NimMax-style Context API",
      "Session management",
      "Flash messages",
      "Form validation",
      "CSRF protection"
    ]
  })

proc flashHandler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  let session = ctx.session()
  session.flash("Welcome back!", flSuccess)
  let msgs = session.getFlashedMsgs()
  var html = "<h1>Flash Messages</h1><ul>"
  for (level, msg) in msgs:
    html &= "<li>" & $level & ": " & msg & "</li>"
  html &= "</ul><p><a href='/'>Back</a></p>"
  ctx.html(html)

proc csrfFormHandler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  let token = ctx.request.csrfTokenInput()
  ctx.html("""
  <!DOCTYPE html>
  <html>
  <head><title>CSRF Protected Form</title></head>
  <body>
    <h1>CSRF Protected Form</h1>
    <form method="POST" action="/submit">
      <input type="hidden" name="csrf_token" value=""" & token & """ />
      <label>Name: <input type="text" name="name" /></label>
      <button type="submit">Submit</button>
    </form>
  </body>
  </html>
  """)

proc submitHandler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  ctx.text("Form submitted successfully!")

var appRouter = newRouter()
appRouter.get("/", indexHandler)
appRouter.get("/user/@id", userHandler)
appRouter.get("/api", apiHandler)
appRouter.get("/flash", flashHandler)
appRouter.get("/form", csrfFormHandler)
appRouter.post("/submit", submitHandler)

# Custom error handlers (NimMax-style)
appRouter.notFoundHandler = proc(request: Request) =
  let ctx = newContext(request)
  ctx.json(%*{"error": "Not found", "path": request.path}, 404)

var stack = newMiddlewareStack(appRouter)
stack.use(loggingMiddleware())
stack.use(requestIdMiddleware())
stack.use(recoveryMiddleware())
var sessionStore = newSessionStore()
stack.use(sessionMiddleware(sessionStore))
stack.use(csrfMiddleware())
stack.use(jsonBodyMiddleware())

let server = newServer(stack)
echo "Serving NimMax-style app on http://localhost:8080"
echo "Try these endpoints:"
echo "  GET  /"
echo "  GET  /user/42"
echo "  GET  /api"
echo "  GET  /flash"
# echo "  GET  /validate?email=test@example.com&age=25"
echo "  GET  /form"
echo "  POST /submit (with CSRF token)"
server.serve(Port(8080))
