when not defined(nimdoc):
  when not defined(gcArc) and not defined(gcOrc) and not defined(gcAtomicArc):
    {.error: "Using --mm:arc, --mm:orc or --mm:atomicArc is required by Hunos.".}

when not compileOption("threads"):
  {.error: "Using --threads:on is required by Hunos.".}

import hunos/common, hunos/internal, hunos/sha, hunos/compress
import std/atomics, std/cpuinfo, std/deques, std/hashes,
    std/nativesockets, std/os, std/random,
    std/selectors, std/sets, std/tables, std/times

from std/strutils import find, cmpIgnoreCase, toLowerAscii, split

when defined(linux):
  when defined(nimdoc):
    from std/posix import write, TPollfd, POLLIN, poll, close, EAGAIN, O_CLOEXEC, O_NONBLOCK
  else:
    import std/posix
  let SOCK_NONBLOCK
    {.importc: "SOCK_NONBLOCK", header: "<sys/socket.h>".}: cint

when defined(windows):
  from std/winlean import TCP_NODELAY
elif defined(posix) and not defined(linux):
  from std/posix import TCP_NODELAY

import std/locks

export Port, common, internal

const
  whitespace = {' ', '\t'}
  listenBacklogLen = 128
  maxEventsPerSelectLoop = 64
  initialRecvBufLen = (4 * 1024) - 9

let
  http10 = "HTTP/1.0"
  http11 = "HTTP/1.1"

type
  RequestObj* = object
    httpVersion*: HttpVersion
    httpMethod*: string
    uri*: string
    path*: string
    queryParams*: seq[(string, string)]
    pathParams*: PathParams
    headers*: HttpHeaders
    body*: string
    remoteAddress*: string
    server*: Server
    clientSocket: SocketHandle
    clientId: uint64
    responded: bool
    responseHeaders*: HttpHeaders

  Request* = ptr RequestObj

  WebSocket* = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  Message* = object
    kind*: MessageKind
    data*: string

  WebSocketEvent* = enum
    OpenEvent, MessageEvent, ErrorEvent, CloseEvent

  MessageKind* = enum
    TextMessage, BinaryMessage, Ping, Pong

  RequestHandler* = proc(request: Request) {.gcsafe.}

  WebSocketHandler* = proc(
    websocket: WebSocket,
    event: WebSocketEvent,
    message: Message
  ) {.gcsafe.}

  ServerObj = object
    handler: RequestHandler
    websocketHandler: WebSocketHandler
    logHandler: LogHandler
    maxHeadersLen, maxBodyLen, maxMessageLen: int
    tcpNoDelay: bool
    rand: Rand
    workerThreads: seq[Thread[Server]]
    serving: Atomic[bool]
    destroyCalled: bool
    socket: SocketHandle
    selector: Selector[DataEntry]
    responseQueued, sendQueued, shutdown: SelectEvent
    clientSockets: HashSet[SocketHandle]
    taskQueueLock: Lock
    taskQueueCond: Cond
    taskQueue: Deque[WorkerTask]
    responseQueue: Deque[OutgoingBuffer]
    responseQueueLock: Lock
    sendQueue: Deque[OutgoingBuffer]
    sendQueueLock: Lock
    websocketClaimed: Table[WebSocket, bool]
    websocketQueues: Table[WebSocket, Deque[WebSocketUpdate]]
    websocketQueuesLock: Lock

  Server* = ptr ServerObj

  WorkerTask = object
    request: Request
    websocket: WebSocket

  DataEntryKind = enum
    ServerSocketEntry, ClientSocketEntry, EventEntry

  DataEntry {.acyclic.} = ref object
    case kind: DataEntryKind:
    of ServerSocketEntry:
      discard
    of EventEntry:
      event: SelectEvent
    of ClientSocketEntry:
      clientId: uint64
      remoteAddress: string
      recvBuf: string
      bytesReceived: int
      requestState: IncomingRequestState
      frameState: IncomingFrameState
      outgoingBuffers: Deque[OutgoingBuffer]
      closeFrameQueuedAt: float64
      upgradedToWebSocket, closeFrameSent: bool
      sendsWaitingForUpgrade: seq[OutgoingBuffer]
      requestCounter: int

  IncomingRequestState = object
    headersParsed: bool
    chunked: bool
    loggedUnexpectedData: bool
    contentLength: int
    httpVersion: HttpVersion
    httpMethod: string
    uri: string
    path: string
    queryParams: seq[(string, string)]
    headers: HttpHeaders
    body: string

  IncomingFrameState = object
    opcode: uint8
    buffer: string
    frameLen: int

  OutgoingBuffer {.acyclic.} = ref object
    clientSocket: SocketHandle
    clientId: uint64
    closeConnection, isWebSocketUpgrade, isCloseFrame: bool
    buffer1, buffer2: string
    bytesSent: int

  WebSocketUpdate = object
    event: WebSocketEvent
    message: Message

type QueryParam = (string, string)

proc parseUrl(uri: string): tuple[path: string, query: seq[QueryParam]] =
  let qPos = uri.find('?')
  if qPos == -1:
    return (uri, @[])
  let path = uri[0 ..< qPos]
  let queryStr = uri[qPos + 1 .. ^1]
  var params: seq[QueryParam]
  for pair in queryStr.split('&'):
    let eqPos = pair.find('=')
    if eqPos == -1:
      params.add((pair, ""))
    else:
      params.add((pair[0 ..< eqPos], pair[eqPos + 1 .. ^1]))
  return (path, params)

proc `$`*(request: Request): string {.gcsafe.} =
  result = request.httpMethod & " " & request.uri & " "
  {.gcsafe.}:
    case request.httpVersion:
    of Http10:
      result &= http10
    else:
      result &= http11
  result &= " (" & $cast[uint](request) & ")"

proc `$`*(websocket: WebSocket): string =
  "WebSocket " & $cast[uint](hash(websocket))

proc log*(server: Server, level: LogLevel, args: varargs[string]) =
  if server.logHandler == nil:
    return
  try:
    server.logHandler(level, args)
  except Exception:
    discard

proc log*(request: Request, level: LogLevel, args: varargs[string]) =
  request.server.log(level, args)

proc registerHandle2(
  selector: Selector[DataEntry],
  socket: SocketHandle,
  events: set[Event],
  data: DataEntry
) {.raises: [IOSelectorsException].} =
  try:
    selector.registerHandle(socket, events, data)
  except ValueError:
    raise newException(IOSelectorsException, getCurrentExceptionMsg())

proc updateHandle2(
  selector: Selector[DataEntry],
  socket: SocketHandle,
  events: set[Event]
) {.raises: [IOSelectorsException].} =
  try:
    selector.updateHandle(socket, events)
  except ValueError:
    raise newException(IOSelectorsException, getCurrentExceptionMsg())

proc trigger(
  server: Server,
  event: SelectEvent
) {.raises: [].} =
  try:
    event.trigger()
  except Exception:
    let err = osLastError()
    server.log(ErrorLevel, "Error triggering event ", $err, " ", osErrorMsg(err))

proc setNoDelay(
  server: Server,
  socket: SocketHandle
) {.raises: [].} =
  try:
    socket.setSockOptInt(Protocol.IPPROTO_TCP.int, TCP_NODELAY.int, 1)
  except Exception as e:
    server.log(ErrorLevel, "Error setting TCP_NODELAY: ", e.msg)

proc send*(
  websocket: WebSocket,
  data: sink string,
  kind = TextMessage,
) {.raises: [], gcsafe.} =
  var encodedFrame = OutgoingBuffer()
  encodedFrame.clientSocket = websocket.clientSocket
  encodedFrame.clientId = websocket.clientId

  case kind:
  of TextMessage:
    encodedFrame.buffer1 = encodeFrameHeader(0x1, data.len)
  of BinaryMessage:
    encodedFrame.buffer1 = encodeFrameHeader(0x2, data.len)
  of Ping:
    encodedFrame.buffer1 = encodeFrameHeader(0x9, data.len)
  of Pong:
    encodedFrame.buffer1 = encodeFrameHeader(0xA, data.len)

  encodedFrame.buffer2 = move data

  var queueWasEmpty: bool
  withLock websocket.server.sendQueueLock:
    queueWasEmpty = websocket.server.sendQueue.len == 0
    websocket.server.sendQueue.addLast(move encodedFrame)

  if queueWasEmpty:
    websocket.server.trigger(websocket.server.sendQueued)

proc close*(websocket: WebSocket) {.raises: [], gcsafe.} =
  var encodedFrame = OutgoingBuffer()
  encodedFrame.clientSocket = websocket.clientSocket
  encodedFrame.clientId = websocket.clientId
  encodedFrame.buffer1 = encodeFrameHeader(0x8, 0)
  encodedFrame.isCloseFrame = true

  var queueWasEmpty: bool
  withLock websocket.server.sendQueueLock:
    queueWasEmpty = websocket.server.sendQueue.len == 0
    websocket.server.sendQueue.addLast(move encodedFrame)

  if queueWasEmpty:
    websocket.server.trigger(websocket.server.sendQueued)

proc respond*(
  request: Request,
  statusCode: int,
  headers: sink HttpHeaders = @[],
  body: sink string = ""
) {.raises: [], gcsafe.}

proc respond*(
  request: Request,
  response: sink Response
) {.raises: [], gcsafe.} =
  request.respond(response.code, response.headers, response.body)

proc respond*(
  request: Request,
  statusCode: int,
  headers: sink HttpHeaders = @[],
  body: sink string = ""
) {.raises: [], gcsafe.} =
  if request.responded:
    request.server.log(
      InfoLevel,
      "Responding to a request that has already received a non-1xx response"
    )

  var encodedResponse = OutgoingBuffer()
  encodedResponse.clientSocket = request.clientSocket
  encodedResponse.clientId = request.clientId
  encodedResponse.closeConnection = request.httpVersion == Http10

  if request.headers.headerContainsToken("Connection", "close"):
    encodedResponse.closeConnection = true
  elif request.headers.headerContainsToken("Connection", "keep-alive"):
    encodedResponse.closeConnection = false

  if not encodedResponse.closeConnection:
    encodedResponse.closeConnection = headers.headerContainsToken(
      "Connection", "close"
    )

  if encodedResponse.closeConnection:
    headers["Connection"] = "close"
  elif request.httpVersion == Http10:
    headers["Connection"] = "keep-alive"

  for (k, v) in request.responseHeaders:
    if k notin headers:
      headers[k] = v

  if body.len > compressMinLen and "Content-Encoding" notin headers:
    let acceptEncoding = request.headers["Accept-Encoding"]
    if acceptEncoding.len > 0:
      let (compressed, encoding) = compressBody(body, acceptEncoding)
      if encoding.len > 0:
        body = compressed
        headers["Content-Encoding"] = encoding

  if "Content-Length" notin headers:
    let shouldAddContentLengthHeader =
      statusCode != 204 and (statusCode < 100 or statusCode >= 200)
    if shouldAddContentLengthHeader or body.len > 0:
      headers["Content-Length"] = $body.len

  encodedResponse.buffer1 = encodeHeaders(statusCode, headers, request.httpVersion)
  if encodedResponse.buffer1.len + body.len < 32 * 1024:
    encodedResponse.buffer1 &= body
  else:
    encodedResponse.buffer2 = move body
  encodedResponse.isWebSocketUpgrade = headers.headerContainsToken(
    "Upgrade", "websocket"
  )

  if statusCode < 100 or statusCode >= 200:
    request.responded = true

  var queueWasEmpty: bool
  withLock request.server.responseQueueLock:
    queueWasEmpty = request.server.responseQueue.len == 0
    request.server.responseQueue.addLast(move encodedResponse)

  if queueWasEmpty:
    request.server.trigger(request.server.responseQueued)

proc upgradeToWebSocket*(
  request: Request
): WebSocket {.raises: [HunosError], gcsafe.} =
  if not request.headers.headerContainsToken("Connection", "Upgrade"):
    raise newException(
      HunosError,
      "Invalid request to upgrade, missing 'Connection: upgrade' header"
    )

  if not request.headers.headerContainsToken("Upgrade", "websocket"):
    raise newException(
      HunosError,
      "Invalid request to upgrade, missing 'Upgrade: websocket' header"
    )

  let websocketKey = request.headers["Sec-WebSocket-Key"]
  if websocketKey == "":
    raise newException(
      HunosError,
      "Invalid request to upgrade, missing Sec-WebSocket-Key header"
    )

  let websocketVersion = request.headers["Sec-WebSocket-Version"]
  if websocketVersion != "13":
    raise newException(
      HunosError,
      "Invalid request to upgrade, missing Sec-WebSocket-Version header"
    )

  result = WebSocket(
    server: request.server,
    clientSocket: request.clientSocket,
    clientId: request.clientId
  )

  let hash = sha1(websocketKey & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

  var headers: HttpHeaders
  headers["Connection"] = "Upgrade"
  headers["Upgrade"] = "websocket"
  headers["Sec-WebSocket-Accept"] = base64Encode(hash)

  request.respond(101, headers)

proc workerProc(server: Server) {.raises: [].} =
  let server = server

  proc runTask(task: WorkerTask) =
    if task.request != nil:
      try:
        server.handler(task.request)
      except Exception as e:
        server.log(
          ErrorLevel,
          "Handler exception: " & e.msg & " " & e.getStackTrace()
        )
        if not task.request.responded:
          task.request.respond(500)
      `=destroy`(task.request[])
      deallocShared(task.request)
    else:
      withLock server.websocketQueuesLock:
        if server.websocketClaimed.getOrDefault(task.websocket, true):
          return
        server.websocketClaimed[task.websocket] = true

      while true:
        var hasUpdate = false
        var update: WebSocketUpdate
        withLock server.websocketQueuesLock:
          try:
            if server.websocketQueues[task.websocket].len > 0:
              update = server.websocketQueues[task.websocket].popFirst()
              hasUpdate = true
              if update.event == CloseEvent:
                server.websocketQueues.del(task.websocket)
                server.websocketClaimed.del(task.websocket)
            else:
              server.websocketClaimed[task.websocket] = false
          except KeyError:
            discard

        if not hasUpdate:
          break

        try:
          server.websocketHandler(
            task.websocket,
            update.event,
            move update.message
          )
        except Exception as e:
          server.log(
            ErrorLevel,
            "WebSocket exception: " & e.msg & " " & e.getStackTrace()
          )

        if update.event == CloseEvent:
          break

  while true:
    acquire(server.taskQueueLock)

    while server.taskQueue.len == 0 and not server.destroyCalled:
      wait(server.taskQueueCond, server.taskQueueLock)

    if server.destroyCalled:
      release(server.taskQueueLock)
      return

    let task = server.taskQueue.popFirst()
    release(server.taskQueueLock)

    runTask(task)

proc postTask(server: Server, task: WorkerTask) {.raises: [].} =
  withLock server.taskQueueLock:
    server.taskQueue.addLast(task)
  signal(server.taskQueueCond)

proc postWebSocketUpdate(
  websocket: WebSocket,
  update: sink WebSocketUpdate
) {.raises: [].} =
  if websocket.server.websocketHandler == nil:
    websocket.server.log(DebugLevel, "WebSocket event but no WebSocket handler")
    return

  var needsTask: bool

  withLock websocket.server.websocketQueuesLock:
    if websocket notin websocket.server.websocketQueues:
      return

    try:
      websocket.server.websocketQueues[websocket].addLast(move update)
      if not websocket.server.websocketClaimed[websocket]:
        needsTask = true
    except KeyError:
      discard

  if needsTask:
    websocket.server.postTask(WorkerTask(websocket: websocket))

proc sendCloseFrame(
  server: Server,
  clientSocket: SocketHandle,
  dataEntry: DataEntry,
  closeConnection: bool
) {.raises: [IOSelectorsException].} =
  let outgoingBuffer = OutgoingBuffer()
  outgoingBuffer.clientSocket = clientSocket
  outgoingBuffer.clientId = dataEntry.clientId
  outgoingBuffer.buffer1 = encodeFrameHeader(0x8, 0)
  outgoingBuffer.isCloseFrame = true
  outgoingBuffer.closeConnection = closeConnection
  dataEntry.outgoingBuffers.addLast(outgoingBuffer)
  dataEntry.closeFrameQueuedAt = epochTime()
  server.selector.updateHandle2(clientSocket, {Read, Write})

proc afterRecvWebSocket(
  server: Server,
  clientSocket: SocketHandle,
  dataEntry: DataEntry
): bool {.raises: [IOSelectorsException].} =
  if dataEntry.closeFrameQueuedAt > 0 and
    epochTime() - dataEntry.closeFrameQueuedAt > 10:
    return true

  while true:
    if dataEntry.bytesReceived < 2:
      return false

    let
      b0 = dataEntry.recvBuf[0].uint8
      b1 = dataEntry.recvBuf[1].uint8
      fin = (b0 and 0b10000000) != 0
      rsv1 = b0 and 0b01000000
      rsv2 = b0 and 0b00100000
      rsv3 = b0 and 0b00010000
      opcode = b0 and 0b00001111

    if rsv1 != 0 or rsv2 != 0 or rsv3 != 0:
      return true

    if (b1 and 0b10000000) == 0:
      return true

    if opcode == 0 and dataEntry.frameState.opcode == 0:
      return true

    if dataEntry.frameState.opcode != 0 and opcode != 0:
      return true

    var pos = 2

    var payloadLen = (b1 and 0b01111111).int
    if payloadLen <= 125:
      discard
    elif payloadLen == 126:
      if dataEntry.bytesReceived < 4:
        return false
      var l: uint16
      copyMem(l.addr, dataEntry.recvBuf[pos].addr, 2)
      payloadLen = nativesockets.htons(l).int
      pos += 2
    else:
      if dataEntry.bytesReceived < 10:
        return false
      var l: uint32
      copyMem(l.addr, dataEntry.recvBuf[pos + 4].addr, 4)
      payloadLen = nativesockets.htonl(l).int
      pos += 8

    let isControlFrame = opcode in [0x8.uint8, 0x9, 0xA]
    if isControlFrame and not fin:
      return true
    if payloadLen > 125 and isControlFrame:
      return true

    if dataEntry.frameState.frameLen + payloadLen > server.maxMessageLen:
      server.log(DebugLevel, "Dropped WebSocket, message too long")
      return true

    if dataEntry.bytesReceived < pos + 4:
      return false

    var mask: array[4, uint8]
    copyMem(mask.addr, dataEntry.recvBuf[pos].addr, 4)
    pos += 4

    if dataEntry.bytesReceived < pos + payloadLen:
      return false

    for i in 0 ..< payloadLen:
      let j = i mod 4
      dataEntry.recvBuf[pos + i] =
        (dataEntry.recvBuf[pos + i].uint8 xor mask[j]).char

    if dataEntry.frameState.opcode == 0:
      dataEntry.frameState.opcode = opcode

    let newFrameLen = dataEntry.frameState.frameLen + payloadLen
    if dataEntry.frameState.buffer.len < newFrameLen:
      let newBufferLen = max(dataEntry.frameState.buffer.len * 2, newFrameLen)
      dataEntry.frameState.buffer.setLen(newBufferLen)

    if payloadLen > 0:
      copyMem(
        dataEntry.frameState.buffer[dataEntry.frameState.frameLen].addr,
        dataEntry.recvBuf[pos].addr,
        payloadLen
      )
      dataEntry.frameState.frameLen += payloadLen

    let frameLen = pos + payloadLen
    if dataEntry.bytesReceived == frameLen:
      dataEntry.bytesReceived = 0
    else:
      copyMem(
        dataEntry.recvBuf[0].addr,
        dataEntry.recvBuf[frameLen].addr,
        dataEntry.bytesReceived - frameLen
      )
      dataEntry.bytesReceived -= frameLen

    if fin:
      let frameOpcode = dataEntry.frameState.opcode

      var message: Message
      message.data = move dataEntry.frameState.buffer
      message.data.setLen(dataEntry.frameState.frameLen)

      dataEntry.frameState = IncomingFrameState()

      case frameOpcode:
      of 0x1:
        message.kind = TextMessage
      of 0x2:
        message.kind = BinaryMessage
      of 0x8:
        if dataEntry.closeFrameQueuedAt > 0:
          return true
        server.sendCloseFrame(clientSocket, dataEntry, true)
        continue
      of 0x9:
        message.kind = Ping
      of 0xA:
        message.kind = Pong
      else:
        server.log(DebugLevel, "Dropped WebSocket, received invalid opcode")
        return true

      let
        websocket = WebSocket(
          server: server,
          clientSocket: clientSocket,
          clientId: dataEntry.clientId
        )
        update = WebSocketUpdate(
          event: MessageEvent,
          message: move message
        )
      websocket.postWebSocketUpdate(update)

proc popRequest(
  server: Server,
  clientSocket: SocketHandle,
  dataEntry: DataEntry
): Request {.raises: [].} =
  result = cast[Request](allocShared0(sizeof(RequestObj)))
  result.server = server
  result.clientSocket = clientSocket
  result.clientId = dataEntry.clientId
  result.remoteAddress = dataEntry.remoteAddress
  result.httpVersion = dataEntry.requestState.httpVersion
  result.httpMethod = move dataEntry.requestState.httpMethod
  result.uri = move dataEntry.requestState.uri
  result.path = move dataEntry.requestState.path
  result.queryParams = move dataEntry.requestState.queryParams
  result.headers = move dataEntry.requestState.headers
  result.body = move dataEntry.requestState.body
  result.body.setLen(dataEntry.requestState.contentLength)
  dataEntry.requestState = IncomingRequestState()
  inc dataEntry.requestCounter
  if dataEntry.bytesReceived > 0:
    server.log(DebugLevel, "Receive buffer not empty after request")

proc afterRecvHttp(
  server: Server,
  clientSocket: SocketHandle,
  dataEntry: DataEntry
): bool {.raises: [].} =
  if dataEntry.requestCounter > 0 and
    not dataEntry.requestState.loggedUnexpectedData:
    server.log(
      DebugLevel,
      "Received data before the previous request has been responded to"
    )
    dataEntry.requestState.loggedUnexpectedData = true

  if not dataEntry.requestState.headersParsed:
    let headersEnd = dataEntry.recvBuf.find(
      "\r\n\r\n",
      0,
      min(dataEntry.bytesReceived, server.maxHeadersLen) - 1
    )
    if headersEnd < 0:
      if dataEntry.bytesReceived > server.maxHeadersLen:
        server.log(DebugLevel, "Dropped connection, headers too long")
        return true
      return false

    var lineNum, lineStart: int
    while lineStart < headersEnd:
      var lineEnd = dataEntry.recvBuf.find(
        "\r\n",
        lineStart,
        headersEnd
      )
      if lineEnd == -1:
        lineEnd = headersEnd

      var lineLen = lineEnd - lineStart
      while lineLen > 0 and dataEntry.recvBuf[lineStart] in whitespace:
        inc lineStart
        dec lineLen
      while lineLen > 0 and
        dataEntry.recvBuf[lineStart + lineLen - 1] in whitespace:
        dec lineLen

      if lineNum == 0:
        let space1 = dataEntry.recvBuf.find(
          ' ',
          lineStart,
          lineStart + lineLen - 1
        )
        if space1 == -1:
          return true
        dataEntry.requestState.httpMethod = dataEntry.recvBuf[lineStart ..< space1]
        let
          remainingLen = lineLen - (space1 + 1 - lineStart)
          space2 = dataEntry.recvBuf.find(
            ' ',
            space1 + 1,
            space1 + 1 + remainingLen - 1
          )
        if space2 == -1:
          return true
        dataEntry.requestState.uri = dataEntry.recvBuf[space1 + 1 ..< space2]
        try:
          let parsed = parseUrl(dataEntry.requestState.uri)
          dataEntry.requestState.path = parsed.path
          dataEntry.requestState.queryParams = parsed.query
        except Exception:
          server.log(
            DebugLevel,
            "Dropped connection, invalid request URI: " &
            dataEntry.requestState.uri
          )
          return true
        if dataEntry.recvBuf.find(
          ' ',
          space2 + 1,
          lineStart + lineLen - 1
        ) != -1:
          return true
        let httpVersionLen = lineLen - (space2 + 1 - lineStart)
        if httpVersionLen != 8:
          return true
        {.gcsafe.}:
          if equalMem(
            dataEntry.recvBuf[space2 + 1].addr,
            http11[0].unsafeAddr,
            8
          ):
            dataEntry.requestState.httpVersion = Http11
          elif equalMem(
            dataEntry.recvBuf[space2 + 1].addr,
            http10[0].unsafeAddr,
            8
          ):
            dataEntry.requestState.httpVersion = Http10
          else:
            return true
      else:
        let splitAt = dataEntry.recvBuf.find(
          ':',
          lineStart,
          lineStart + lineLen - 1
        )
        if splitAt == -1:
          var line = dataEntry.recvBuf[lineStart ..< lineStart + lineLen]
          dataEntry.requestState.headers.add((move line, ""))
        else:
          var
            leftStart = lineStart
            leftLen = splitAt - leftStart
            rightStart = splitAt + 1
            rightLen = lineStart + lineLen - rightStart

          while leftLen > 0 and
            dataEntry.recvBuf[leftStart] in whitespace:
            inc leftStart
            dec leftLen
          while leftLen > 0 and
            dataEntry.recvBuf[leftStart + leftLen - 1] in whitespace:
            dec leftLen
          while rightLen > 0 and
            dataEntry.recvBuf[rightStart] in whitespace:
            inc rightStart
            dec rightLen
          while rightLen > 0 and
            dataEntry.recvBuf[rightStart + rightLen - 1] in whitespace:
            dec rightLen

          dataEntry.requestState.headers.add((
            dataEntry.recvBuf[leftStart ..< leftStart + leftLen],
            dataEntry.recvBuf[rightStart ..< rightStart + rightLen]
          ))

      lineStart = lineEnd + 2
      inc lineNum

    dataEntry.requestState.chunked =
      dataEntry.requestState.headers.headerContainsToken(
        "Transfer-Encoding", "chunked"
      )

    var foundContentLength, foundTransferEncoding: bool
    for (k, v) in dataEntry.requestState.headers:
      if cmpIgnoreCase(k, "Content-Length") == 0:
        if foundContentLength:
          return true
        foundContentLength = true
        if dataEntry.requestState.chunked:
          return true
        try:
          dataEntry.requestState.contentLength = strictParseInt(v)
        except Exception:
          return true
      elif cmpIgnoreCase(k, "Transfer-Encoding") == 0:
        if foundTransferEncoding:
          return true
        foundTransferEncoding = true

    if dataEntry.requestState.contentLength < 0:
      return true

    let bodyStart = headersEnd + 4
    if dataEntry.bytesReceived == bodyStart:
      dataEntry.bytesReceived = 0
    else:
      copyMem(
        dataEntry.recvBuf[0].addr,
        dataEntry.recvBuf[bodyStart].addr,
        dataEntry.bytesReceived - bodyStart
      )
      dataEntry.bytesReceived -= bodyStart

    dataEntry.requestState.headersParsed = true

  if dataEntry.requestState.chunked:
    while true:
      if dataEntry.bytesReceived < 3:
        return false

      let chunkLenEnd = dataEntry.recvBuf.find(
        "\r\n",
        0,
        min(dataEntry.bytesReceived - 1, 19)
      )
      if chunkLenEnd < 0:
        if dataEntry.bytesReceived > 19:
          return true
        return false

      var chunkLen: int
      try:
        chunkLen =
          strictParseHex(dataEntry.recvBuf.toOpenArray(0, chunkLenEnd - 1))
      except Exception:
        return true

      if dataEntry.requestState.contentLength + chunkLen > server.maxBodyLen:
        server.log(DebugLevel, "Dropped connection, body too long")
        return true

      let chunkStart = chunkLenEnd + 2
      if dataEntry.bytesReceived < chunkStart + chunkLen + 2:
        return false

      let newContentLength = dataEntry.requestState.contentLength + chunkLen
      if dataEntry.requestState.body.len < newContentLength:
        let newLen = max(dataEntry.requestState.body.len * 2, newContentLength)
        dataEntry.requestState.body.setLen(newLen)

      if chunkLen > 0:
        copyMem(
          dataEntry.requestState.body[dataEntry.requestState.contentLength].addr,
          dataEntry.recvBuf[chunkStart].addr,
          chunkLen
        )
        dataEntry.requestState.contentLength += chunkLen

      let
        nextChunkStart = chunkLenEnd + 2 + chunkLen + 2
        bytesRemaining = dataEntry.bytesReceived - nextChunkStart
      copyMem(
        dataEntry.recvBuf[0].addr,
        dataEntry.recvBuf[nextChunkStart].addr,
        bytesRemaining
      )
      dataEntry.bytesReceived = bytesRemaining

      if chunkLen == 0:
        let request = server.popRequest(clientSocket, dataEntry)
        server.postTask(WorkerTask(request: request))
  else:
    if dataEntry.requestState.contentLength > server.maxBodyLen:
      server.log(DebugLevel, "Dropped connection, body too long")
      return true

    if dataEntry.bytesReceived < dataEntry.requestState.contentLength:
      return false

    if dataEntry.requestState.contentLength > 0:
      if dataEntry.requestState.contentLength == dataEntry.bytesReceived:
        dataEntry.requestState.body = move dataEntry.recvBuf
        dataEntry.recvBuf.setLen(initialRecvBufLen)
        dataEntry.bytesReceived = 0
      else:
        dataEntry.requestState.body.setLen(dataEntry.requestState.contentLength)
        copyMem(
          dataEntry.requestState.body[0].addr,
          dataEntry.recvBuf[0].addr,
          dataEntry.requestState.contentLength
        )
        let bytesRemaining =
          dataEntry.bytesReceived - dataEntry.requestState.contentLength
        copyMem(
          dataEntry.recvBuf[0].addr,
          dataEntry.recvBuf[dataEntry.requestState.contentLength].addr,
          bytesRemaining
        )
        dataEntry.bytesReceived = bytesRemaining

    let request = server.popRequest(clientSocket, dataEntry)
    server.postTask(WorkerTask(request: request))

proc afterRecv(
  server: Server,
  clientSocket: SocketHandle,
  dataEntry: DataEntry
): bool {.raises: [IOSelectorsException].} =
  if dataEntry.upgradedToWebSocket:
    server.afterRecvWebSocket(clientSocket, dataEntry)
  else:
    server.afterRecvHttp(clientSocket, dataEntry)

proc afterSend(
  server: Server,
  clientSocket: SocketHandle,
  dataEntry: DataEntry
): bool {.raises: [IOSelectorsException].} =
  let
    outgoingBuffer = dataEntry.outgoingBuffers.peekFirst()
    totalBytes = outgoingBuffer.buffer1.len + outgoingBuffer.buffer2.len
  if outgoingBuffer.bytesSent == totalBytes:
    dataEntry.outgoingBuffers.shrink(fromFirst = 1)
    if outgoingBuffer.isCloseFrame:
      dataEntry.closeFrameSent = true
    if outgoingBuffer.closeConnection:
      return true
  if dataEntry.outgoingBuffers.len == 0:
    server.selector.updateHandle2(clientSocket, {Read})

proc destroy(server: Server, joinThreads: bool) {.raises: [].} =
  withLock server.taskQueueLock:
    server.destroyCalled = true
  if server.selector != nil:
    try:
      server.selector.close()
    except Exception:
      discard
  if server.socket.int != 0:
    server.socket.close()
  for clientSocket in server.clientSockets:
    clientSocket.close()
  broadcast(server.taskQueueCond)
  if joinThreads:
    joinThreads(server.workerThreads)
    deinitLock(server.taskQueueLock)
    deinitCond(server.taskQueueCond)
    deinitLock(server.responseQueueLock)
    deinitLock(server.sendQueueLock)
    deinitLock(server.websocketQueuesLock)
    try:
      server.responseQueued.close()
    except Exception:
      discard
    try:
      server.sendQueued.close()
    except Exception:
      discard
    try:
      server.shutdown.close()
    except Exception:
      discard
    `=destroy`(server[])
    deallocShared(server)
  else:
    discard

{.push warning[ProveInit]: off.}
proc loopForever(server: Server) {.raises: [IOSelectorsException].} =
  var
    readyKeys: array[maxEventsPerSelectLoop, ReadyKey]
    receivedFrom, sentTo: seq[SocketHandle]
    needClosing: HashSet[SocketHandle]
    encodedResponses: seq[OutgoingBuffer]
    encodedFrames: seq[OutgoingBuffer]
  while true:
    receivedFrom.setLen(0)
    sentTo.setLen(0)
    needClosing.clear()
    encodedResponses.setLen(0)
    encodedFrames.setLen(0)

    let readyCount = server.selector.selectInto(-1, readyKeys)

    var responseQueuedTriggered, sendQueuedTriggered, shutdownTriggered: bool
    for i in 0 ..< readyCount:
      let readyKey = readyKeys[i]
      if User in readyKey.events:
        let eventDataEntry = server.selector.getData(readyKey.fd)
        if eventDataEntry.event == server.responseQueued:
          responseQueuedTriggered = true
        if eventDataEntry.event == server.sendQueued:
          sendQueuedTriggered = true
        elif eventDataEntry.event == server.shutdown:
          shutdownTriggered = true

    if responseQueuedTriggered:
      withLock server.responseQueueLock:
        while server.responseQueue.len > 0:
          encodedResponses.add(server.responseQueue.popFirst())

      for encodedResponse in encodedResponses:
        if encodedResponse.clientSocket in server.selector:
          let clientDataEntry =
            server.selector.getData(encodedResponse.clientSocket)
          if encodedResponse.clientId == clientDataEntry.clientId:
            clientDataEntry.outgoingBuffers.addLast(encodedResponse)
            server.selector.updateHandle2(
              encodedResponse.clientSocket,
              {Read, Write}
            )

            clientDataEntry.requestCounter =
              max(clientDataEntry.requestCounter - 1, 0)

            if encodedResponse.isWebSocketUpgrade:
              clientDataEntry.upgradedToWebSocket = true
              let websocket = WebSocket(
                server: server,
                clientSocket: encodedResponse.clientSocket,
                clientId: encodedResponse.clientId
              )
              withLock server.websocketQueuesLock:
                server.websocketQueues[websocket] = initDeque[WebSocketUpdate]()
                server.websocketClaimed[websocket] = false
              websocket.postWebSocketUpdate(WebSocketUpdate(event: OpenEvent))
              if clientDataEntry.sendsWaitingForUpgrade.len > 0:
                for encodedFrame in clientDataEntry.sendsWaitingForUpgrade:
                  if clientDataEntry.closeFrameQueuedAt > 0:
                    server.log(DebugLevel, "Dropped message after WebSocket close")
                  else:
                    clientDataEntry.outgoingBuffers.addLast(encodedFrame)
                    if encodedFrame.isCloseFrame:
                      clientDataEntry.closeFrameQueuedAt = epochTime()
                clientDataEntry.sendsWaitingForUpgrade.setLen(0)
          else:
            server.log(DebugLevel, "Dropped response to disconnected client")
        else:
          server.log(DebugLevel, "Dropped response to disconnected client")

    if sendQueuedTriggered:
      withLock server.sendQueueLock:
        while server.sendQueue.len > 0:
          encodedFrames.add(server.sendQueue.popFirst())

      for encodedFrame in encodedFrames:
        if encodedFrame.clientSocket in server.selector:
          let clientDataEntry =
            server.selector.getData(encodedFrame.clientSocket)
          if encodedFrame.clientId == clientDataEntry.clientId:
            if clientDataEntry.upgradedToWebSocket:
              if clientDataEntry.closeFrameQueuedAt > 0:
                server.log(DebugLevel, "Dropped message after WebSocket close")
              else:
                clientDataEntry.outgoingBuffers.addLast(encodedFrame)
                if encodedFrame.isCloseFrame:
                  clientDataEntry.closeFrameQueuedAt = epochTime()
                server.selector.updateHandle2(
                  encodedFrame.clientSocket,
                  {Read, Write}
                )
            else:
              clientDataEntry.sendsWaitingForUpgrade.add(encodedFrame)
          else:
            server.log(DebugLevel, "Dropped message to disconnected client")
        else:
          server.log(DebugLevel, "Dropped message to disconnected client")

    if shutdownTriggered:
      server.destroy(true)
      return

    for i in 0 ..< readyCount:
      let readyKey = readyKeys[i]

      if readyKey.fd == server.socket.int:
        if Read in readyKey.events:
          let (clientSocket, remoteAddress) =
            when defined(linux) and not defined(nimdoc):
              var
                sockAddr: SockAddr
                addrLen = sizeof(sockAddr).SockLen
              let
                socket =
                  accept4(
                    server.socket,
                    sockAddr.addr,
                    addrLen.addr,
                    SOCK_CLOEXEC or SOCK_NONBLOCK
                  )
                sockAddrStr =
                  try:
                    getAddrString(sockAddr.addr)
                  except Exception:
                    ""
              (socket, sockAddrStr)
            else:
              server.socket.accept()

          if clientSocket == osInvalidSocket:
            continue

          when not defined(linux):
            clientSocket.setBlocking(false)

          if server.tcpNoDelay:
            server.setNoDelay(clientSocket)

          server.clientSockets.incl(clientSocket)

          let dataEntry = DataEntry(kind: ClientSocketEntry)
          dataEntry.clientId = server.rand.next()
          dataEntry.remoteAddress = remoteAddress
          dataEntry.recvBuf.setLen(initialRecvBufLen)
          server.selector.registerHandle2(clientSocket, {Read}, dataEntry)
      else:
        if Error in readyKey.events:
          needClosing.incl(readyKey.fd.SocketHandle)
          continue

        let dataEntry = server.selector.getData(readyKey.fd)

        if Read in readyKey.events:
          if dataEntry.bytesReceived == dataEntry.recvBuf.len:
            dataEntry.recvBuf.setLen(dataEntry.recvBuf.len * 2)

          let bytesReceived = readyKey.fd.SocketHandle.recv(
            dataEntry.recvBuf[dataEntry.bytesReceived].addr,
            (dataEntry.recvBuf.len - dataEntry.bytesReceived).cint,
            0
          )
          if bytesReceived > 0:
            dataEntry.bytesReceived += bytesReceived
            receivedFrom.add(readyKey.fd.SocketHandle)
          else:
            needClosing.incl(readyKey.fd.SocketHandle)
            continue

        if Write in readyKey.events:
          let
            outgoingBuffer = dataEntry.outgoingBuffers.peekFirst()
            bytesSent =
              if outgoingBuffer.bytesSent < outgoingBuffer.buffer1.len:
                readyKey.fd.SocketHandle.send(
                  outgoingBuffer.buffer1[outgoingBuffer.bytesSent].addr,
                  (outgoingBuffer.buffer1.len - outgoingBuffer.bytesSent).cint,
                  when defined(MSG_NOSIGNAL): MSG_NOSIGNAL else: 0
                )
              else:
                let buffer2Pos =
                  outgoingBuffer.bytesSent - outgoingBuffer.buffer1.len
                readyKey.fd.SocketHandle.send(
                  outgoingBuffer.buffer2[buffer2Pos].addr,
                  (outgoingBuffer.buffer2.len - buffer2Pos).cint,
                  when defined(MSG_NOSIGNAL): MSG_NOSIGNAL else: 0
                )
          if bytesSent > 0:
            outgoingBuffer.bytesSent += bytesSent
            sentTo.add(readyKey.fd.SocketHandle)
          else:
            needClosing.incl(readyKey.fd.SocketHandle)
            continue

    for clientSocket in receivedFrom:
      if clientSocket in needClosing:
        continue
      let
        dataEntry = server.selector.getData(clientSocket)
        needsClosing = server.afterRecv(clientSocket, dataEntry)
      if needsClosing:
        needClosing.incl(clientSocket)

    for clientSocket in sentTo:
      if clientSocket in needClosing:
        continue
      let
        dataEntry = server.selector.getData(clientSocket)
        needsClosing = server.afterSend(clientSocket, dataEntry)
      if needsClosing:
        needClosing.incl(clientSocket)

    for clientSocket in needClosing:
      let dataEntry = server.selector.getData(clientSocket)
      try:
        server.selector.unregister(clientSocket)
      except Exception:
        server.log(DebugLevel, "Error unregistering client socket")
      finally:
        clientSocket.close()
        server.clientSockets.excl(clientSocket)
      if dataEntry.upgradedToWebSocket:
        let websocket = WebSocket(
          server: server,
          clientSocket: clientSocket,
          clientId: dataEntry.clientId
        )
        if not dataEntry.closeFrameSent:
          var error = WebSocketUpdate(event: ErrorEvent)
          websocket.postWebSocketUpdate(error)
        var close = WebSocketUpdate(event: CloseEvent)
        websocket.postWebSocketUpdate(close)
{.pop.}

proc close*(server: Server) {.raises: [], gcsafe.}

proc shutdown*(server: Server, timeout: int = 30) {.raises: [], gcsafe.} =
  server.serving.store(false)
  if server.socket.int != 0:
    try:
      server.socket.close()
    except Exception:
      discard
    server.socket = osInvalidSocket
  let deadline = epochTime() + timeout.float
  while epochTime() < deadline:
    var empty: bool
    withLock server.taskQueueLock:
      empty = server.taskQueue.len == 0
    if empty:
      break
    sleep(100)
  server.close()

proc close*(server: Server) {.raises: [], gcsafe.} =
  if server.socket.int != 0:
    server.trigger(server.shutdown)
  else:
    server.destroy(true)

proc serve*(
  server: Server,
  port: Port,
  address = "localhost"
) {.raises: [HunosError].} =
  if server.socket.int != 0:
    raise newException(HunosError, "Server already has a socket")

  try:
    server.socket = createNativeSocket(
      Domain.AF_INET,
      SockType.SOCK_STREAM,
      Protocol.IPPROTO_TCP,
      false
    )
    if server.socket == osInvalidSocket:
      raiseOSError(osLastError())

    server.socket.setBlocking(false)
    server.socket.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)

    let ai = getAddrInfo(
      address,
      port,
      Domain.AF_INET,
      SockType.SOCK_STREAM,
      Protocol.IPPROTO_TCP,
    )
    try:
      if bindAddr(server.socket, ai.ai_addr, ai.ai_addrlen.SockLen) < 0:
        raiseOSError(osLastError())
    finally:
      freeAddrInfo(ai)

    if nativesockets.listen(server.socket, listenBacklogLen) < 0:
      raiseOSError(osLastError())

    let dataEntry = DataEntry(kind: ServerSocketEntry)
    server.selector.registerHandle2(server.socket, {Read}, dataEntry)
  except Exception:
    server.destroy(true)
    raise currentExceptionAsHunosError()

  server.serving.store(true, moRelaxed)

  try:
    server.loopForever()
  except Exception as e:
    server.log(ErrorLevel, e.msg & "\n" & e.getStackTrace())
    server.destroy(false)
    raise currentExceptionAsHunosError()

proc newServer*(
  handler: RequestHandler,
  websocketHandler: WebSocketHandler = nil,
  logHandler: LogHandler = nil,
  workerThreads = max(countProcessors() * 10, 1),
  maxHeadersLen = 8 * 1024,
  maxBodyLen = 1024 * 1024,
  maxMessageLen = 64 * 1024,
  tcpNoDelay = true
): Server {.raises: [HunosError].} =
  if handler == nil:
    raise newException(HunosError, "The request handler must not be nil")

  var workerThreads = workerThreads
  when defined(hunosNoWorkers):
    workerThreads = 0

  result = cast[Server](allocShared0(sizeof(ServerObj)))
  result.handler = handler
  result.websocketHandler = websocketHandler
  result.logHandler = if logHandler != nil: logHandler else: echoLogger
  result.maxHeadersLen = maxHeadersLen
  result.maxBodyLen = maxBodyLen
  result.maxMessageLen = maxMessageLen
  result.tcpNoDelay = tcpNoDelay
  result.rand = initRand()

  result.workerThreads.setLen(workerThreads)

  try:
    result.responseQueued = newSelectEvent()
    result.sendQueued = newSelectEvent()
    result.shutdown = newSelectEvent()

    result.selector = newSelector[DataEntry]()

    let responseQueuedData = DataEntry(kind: EventEntry)
    responseQueuedData.event = result.responseQueued
    result.selector.registerEvent(result.responseQueued, responseQueuedData)

    let sendQueuedData = DataEntry(kind: EventEntry)
    sendQueuedData.event = result.sendQueued
    result.selector.registerEvent(result.sendQueued, sendQueuedData)

    let shutdownData = DataEntry(kind: EventEntry)
    shutdownData.event = result.shutdown
    result.selector.registerEvent(result.shutdown, shutdownData)

    initLock(result.taskQueueLock)
    initCond(result.taskQueueCond)
    initLock(result.responseQueueLock)
    initLock(result.sendQueueLock)
    initLock(result.websocketQueuesLock)

    for i in 0 ..< workerThreads:
      createThread(result.workerThreads[i], workerProc, result)
  except Exception:
    result.destroy(true)
    raise currentExceptionAsHunosError()

proc responded*(request: Request): bool =
  request.responded

proc getCookie*(request: Request, name: string): string =
  let cookieHeader = request.headers["Cookie"]
  if cookieHeader.len == 0:
    return ""
  var i = 0
  while i < cookieHeader.len:
    var start = i
    while i < cookieHeader.len and cookieHeader[i] == ' ':
      inc i
    start = i
    while i < cookieHeader.len and cookieHeader[i] != ';':
      inc i
    var pairLen = i - start
    while pairLen > 0 and cookieHeader[start + pairLen - 1] == ' ':
      dec pairLen
    if pairLen > name.len + 1 and cookieHeader[start ..< start + name.len] == name and
       cookieHeader[start + name.len] == '=':
      return cookieHeader[start + name.len + 1 ..< start + pairLen]
    if i < cookieHeader.len and cookieHeader[i] == ';':
      inc i
  return ""

proc setCookie*(
  headers: var HttpHeaders,
  name, value: string,
  path: string = "",
  maxAge: int = 0,
  httpOnly: bool = false,
  secure: bool = false,
  sameSite: string = ""
) =
  var cookie = name & "=" & value
  if path.len > 0:
    cookie &= "; Path=" & path
  if maxAge > 0:
    cookie &= "; Max-Age=" & $maxAge
  if httpOnly:
    cookie &= "; HttpOnly"
  if secure:
    cookie &= "; Secure"
  if sameSite.len > 0:
    cookie &= "; SameSite=" & sameSite
  headers.add(("Set-Cookie", cookie))

proc setCookie*(
  request: Request,
  name, value: string,
  path: string = "",
  maxAge: int = 0,
  httpOnly: bool = false,
  secure: bool = false,
  sameSite: string = ""
) =
  request.responseHeaders.setCookie(name, value, path, maxAge, httpOnly, secure, sameSite)

proc waitUntilReady*(server: Server, timeout: float = 10) =
  let start = cpuTime()
  while true:
    if server.serving.load(moRelaxed):
      return
    let
      now = cpuTime()
      delta = now - start
    if delta > timeout:
      raise newException(HunosError, "Timeout while waiting for server")
    sleep(100)
