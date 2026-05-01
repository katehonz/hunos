import hunos

proc handler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "Hello, World!")

let server = newServer(handler)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
