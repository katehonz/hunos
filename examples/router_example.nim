import hunos, hunos/router

proc indexHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "Hello, World!")

proc userHandler(request: Request) =
  let userId = request.pathParams["id"]
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "User: " & userId)

proc searchHandler(request: Request) =
  let query = request.queryParams
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  var response = "Search results for: "
  for (k, v) in query:
    response &= k & "=" & v & " "
  request.respond(200, headers, response)

var router: Router
router.get("/", indexHandler)
router.get("/user/@id", userHandler)
router.get("/search", searchHandler)

let server = newServer(router)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
