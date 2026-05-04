## test_h2_integration.nim
##
## Integration test for h2c (cleartext HTTP/2) with Hunos server.

import hunos, hunos/h2, std/os, std/net

type
  ServerWithPort = object
    server: Server
    port: int

proc serveProc(sp: ServerWithPort) {.thread.} =
  sp.server.serve(Port(sp.port))

proc sendH2cPreface(socket: Socket) =
  socket.send(connectionPreface)

proc sendH2cSettings(socket: Socket) =
  var settings: seq[(SettingsParam, uint32)] = @[]
  settings.add((spInitialWindowSize, 65535'u32))
  settings.add((spMaxConcurrentStreams, 100'u32))
  let payload = encodeSettingsPayload(settings)
  let frame = Frame(
    frameType: ftSettings,
    flags: 0,
    streamId: 0,
    payload: payload
  )
  socket.send(encodeFrame(frame))

proc recvFrame(socket: Socket, timeout = 5000): Frame =
  var headerBuf = newString(9)
  let bytesRead = socket.recv(headerBuf, 9)
  if bytesRead < 9:
    return Frame()

  let length = (headerBuf[0].uint32 shl 16) or (headerBuf[1].uint32 shl 8) or headerBuf[2].uint32
  let frameType = FrameType(headerBuf[3])
  let flags = headerBuf[4].uint8
  let streamId = ((headerBuf[5].uint32 and 0x7F'u32) shl 24) or
                 (headerBuf[6].uint32 shl 16) or
                 (headerBuf[7].uint32 shl 8) or
                 headerBuf[8].uint32

  var payload = newString(length.int)
  if length > 0:
    discard socket.recv(payload, length.int)

  result = Frame(
    frameType: frameType,
    flags: flags,
    streamId: streamId,
    payload: payload
  )

proc sendH2cRequest(socket: Socket, streamId: uint32, headers: seq[(string, string)], body: string = "") =
  var h2Conn = newH2Connection()
  let headerBlock = encodeHpackHeaders(h2Conn, headers)

  var flags = uint8(ffEndHeaders)
  if body.len == 0:
    flags = flags or uint8(ffEndStream)

  let headersFrame = Frame(
    frameType: ftHeaders,
    flags: flags,
    streamId: streamId,
    payload: headerBlock
  )
  socket.send(encodeFrame(headersFrame))

  if body.len > 0:
    let dataFrame = makeDataFrame(streamId, body, endStream = true)
    socket.send(encodeFrame(dataFrame))

proc testH2cBasicRequest() =
  echo "[TEST] H2C basic GET request"

  proc handler(request: Request) {.gcsafe.} =
    request.respond(200, body = "Hello HTTP/2!")

  let server = newServer(handler, workerThreads = 2)
  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8070))
  server.waitUntilReady()

  var socket = newSocket()
  socket.connect("127.0.0.1", Port(8070))

  sendH2cPreface(socket)
  sendH2cSettings(socket)

  # Read server SETTINGS
  let serverSettings = recvFrame(socket)
  assert serverSettings.frameType == ftSettings, "Server should send SETTINGS"

  # Send SETTINGS ACK
  let ackFrame = Frame(
    frameType: ftSettings,
    flags: uint8(ffAck),
    streamId: 0,
    payload: ""
  )
  socket.send(encodeFrame(ackFrame))

  # Read server SETTINGS ACK
  let serverAck = recvFrame(socket)
  assert serverAck.frameType == ftSettings, "Server should send SETTINGS ACK"
  assert (serverAck.flags and uint8(ffAck)) != 0, "Should be ACK"

  # Send request
  var reqHeaders: seq[(string, string)] = @[]
  reqHeaders.add((":method", "GET"))
  reqHeaders.add((":path", "/"))
  reqHeaders.add((":scheme", "http"))
  reqHeaders.add((":authority", "localhost"))
  sendH2cRequest(socket, 1, reqHeaders)

  # Read response
  let respHeaders = recvFrame(socket)
  assert respHeaders.frameType == ftHeaders, "Should receive HEADERS frame, got: " & $respHeaders.frameType

  var respH2Conn = newH2Connection()
  let decodedHeaders = decodeHpackHeaders(respH2Conn, respHeaders.payload)
  var foundStatus = false
  for (k, v) in decodedHeaders:
    if k == ":status":
      assert v == "200", "Status should be 200, got: " & v
      foundStatus = true
  assert foundStatus, "Should have :status pseudo-header"

  # Read data
  let respData = recvFrame(socket)
  assert respData.frameType == ftData, "Should receive DATA frame"
  assert respData.payload == "Hello HTTP/2!", "Body should match, got: " & respData.payload
  assert (respData.flags and uint8(ffEndStream)) != 0, "Should have END_STREAM"

  echo "[OK] H2C basic GET request works"

  socket.close()
  server.close()
  joinThread(serverThread)

proc testH2cPostWithBody() =
  echo "[TEST] H2C POST with body"

  proc handler(request: Request) {.gcsafe.} =
    assert request.body == "Hello from client", "Body should match, got: " & request.body
    request.respond(200, body = "OK: " & request.body)

  let server = newServer(handler, workerThreads = 2)
  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8071))
  server.waitUntilReady()

  var socket = newSocket()
  socket.connect("127.0.0.1", Port(8071))

  sendH2cPreface(socket)
  sendH2cSettings(socket)

  # Drain server settings + ack exchange
  discard recvFrame(socket)  # SETTINGS
  socket.send(encodeFrame(Frame(frameType: ftSettings, flags: uint8(ffAck), streamId: 0, payload: "")))
  discard recvFrame(socket)  # SETTINGS ACK

  # Send POST request
  var reqHeaders: seq[(string, string)] = @[]
  reqHeaders.add((":method", "POST"))
  reqHeaders.add((":path", "/echo"))
  reqHeaders.add((":scheme", "http"))
  reqHeaders.add((":authority", "localhost"))
  reqHeaders.add(("content-type", "text/plain"))
  sendH2cRequest(socket, 1, reqHeaders, "Hello from client")

  # Read response
  let respHeaders = recvFrame(socket)
  assert respHeaders.frameType == ftHeaders

  let respData = recvFrame(socket)
  assert respData.frameType == ftData
  assert respData.payload == "OK: Hello from client", "Body mismatch: " & respData.payload

  echo "[OK] H2C POST with body works"

  socket.close()
  server.close()
  joinThread(serverThread)

proc testH2cMultipleStreams() =
  echo "[TEST] H2C multiple concurrent streams"

  proc handler(request: Request) {.gcsafe.} =
    let path = request.path
    request.respond(200, body = "Response for " & path)

  let server = newServer(handler, workerThreads = 4)
  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8072))
  server.waitUntilReady()

  var socket = newSocket()
  socket.connect("127.0.0.1", Port(8072))

  sendH2cPreface(socket)
  sendH2cSettings(socket)

  discard recvFrame(socket)  # SETTINGS
  socket.send(encodeFrame(Frame(frameType: ftSettings, flags: uint8(ffAck), streamId: 0, payload: "")))
  discard recvFrame(socket)  # SETTINGS ACK

  # Send 3 requests on different streams
  for streamId in [1'u32, 3'u32, 5'u32]:
    var reqHeaders: seq[(string, string)] = @[]
    reqHeaders.add((":method", "GET"))
    reqHeaders.add((":path", "/stream" & $streamId))
    reqHeaders.add((":scheme", "http"))
    reqHeaders.add((":authority", "localhost"))
    sendH2cRequest(socket, streamId, reqHeaders)

  # Read 3 responses (each is HEADERS + DATA)
  var responsesReceived = 0
  for i in 0 ..< 6:
    let frame = recvFrame(socket)
    if frame.frameType == ftData:
      assert (frame.flags and uint8(ffEndStream)) != 0
      responsesReceived += 1

  assert responsesReceived == 3, "Should receive 3 data frames, got: " & $responsesReceived

  echo "[OK] H2C multiple concurrent streams work"

  socket.close()
  server.close()
  joinThread(serverThread)

proc testH2cPingPong() =
  echo "[TEST] H2C PING/PONG"

  proc handler(request: Request) {.gcsafe.} =
    request.respond(200, body = "ok")

  let server = newServer(handler, workerThreads = 2)
  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8073))
  server.waitUntilReady()

  var socket = newSocket()
  socket.connect("127.0.0.1", Port(8073))

  sendH2cPreface(socket)
  sendH2cSettings(socket)

  discard recvFrame(socket)  # SETTINGS
  socket.send(encodeFrame(Frame(frameType: ftSettings, flags: uint8(ffAck), streamId: 0, payload: "")))
  discard recvFrame(socket)  # SETTINGS ACK

  # Send PING
  let ping = makePingFrame(0xDEADBEEF'u64)
  socket.send(encodeFrame(ping))

  # Read PONG
  let pong = recvFrame(socket)
  assert pong.frameType == ftPing, "Should receive PING"
  assert (pong.flags and uint8(ffAck)) != 0, "Should be ACK"

  echo "[OK] H2C PING/PONG works"

  socket.close()
  server.close()
  joinThread(serverThread)

proc main() =
  testH2cBasicRequest()
  testH2cPostWithBody()
  testH2cMultipleStreams()
  testH2cPingPong()
  echo ""
  echo "All HTTP/2 integration tests passed!"

when isMainModule:
  main()
