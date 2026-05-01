import hunos, hunos/router, std/locks, std/sets

var
  lock: Lock
  clients: HashSet[WebSocket]

initLock(lock)

proc indexHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  request.respond(200, headers, """
  <!DOCTYPE html>
  <script>
    var ws = new WebSocket("ws://localhost:8080/chat")
    ws.onmessage = function(event) {
      var div = document.createElement('div')
      div.textContent = event.data
      document.body.appendChild(div)
    }
    var send = function() {
      ws.send(document.getElementById('msg').value)
    }
  </script>
  <input id="msg" type="text">
  <input type="button" onclick="send()" value="Send">
  <div>Messages received:</div>
  """)

proc upgradeHandler(request: Request) =
  let websocket = request.upgradeToWebSocket()
  websocket.send("Hello from Hunos WebSocket server!")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event:
  of OpenEvent:
    echo "Client connected"
    {.gcsafe.}:
      withLock lock:
        clients.incl(websocket)
  of MessageEvent:
    echo "Message received"
    {.gcsafe.}:
      withLock lock:
        for client in clients:
          client.send(message.data)
  of ErrorEvent:
    discard
  of CloseEvent:
    echo "Client disconnected"
    {.gcsafe.}:
      withLock lock:
        clients.excl(websocket)

var router: Router
router.get("/", indexHandler)
router.get("/chat", upgradeHandler)

let server = newServer(router, websocketHandler)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
