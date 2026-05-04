## testing.nim
##
## Testing utilities for Hunos handlers.
## Provides mock server and synchronous request execution.
##
## Usage:
##   import hunos/testing
##
##   proc handler(request: Request, res: var MockResponse) =
##     res.code = 200
##     res.body = "Hello"
##
##   let response = runOnce(handler, "GET", "/")
##   echo response.code

import ../hunos

proc statusText*(code: int): string =
  case code
  of 200: "OK"
  of 201: "Created"
  of 204: "No Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 304: "Not Modified"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 500: "Internal Server Error"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  else: "Unknown"

proc mockServer*(
  handler: RequestHandler,
  websocketHandler: WebSocketHandler = nil,
  workerThreads = 1,
  maxHeadersLen = 8 * 1024,
  maxBodyLen = 1024 * 1024,
  maxMessageLen = 64 * 1024,
  tcpNoDelay = true
): Server =
  result = newServer(
    handler,
    websocketHandler,
    nil,
    workerThreads,
    maxHeadersLen,
    maxBodyLen,
    maxMessageLen,
    tcpNoDelay
  )

type
  MockResponse* = object
    code*: int
    headers*: HttpHeaders
    body*: string

  TestHandler* = proc(request: Request, res: var MockResponse) {.gcsafe.}

proc runOnce*(
  handler: TestHandler,
  httpMethod: string,
  path: string,
  body = "",
  headers: HttpHeaders = @[]
): MockResponse =

  var response: MockResponse
  response.code = 500
  response.headers = @[]
  response.body = ""

  var mockRequest: RequestObj
  mockRequest.httpVersion = Http11
  mockRequest.httpMethod = httpMethod
  mockRequest.uri = path
  mockRequest.path = path
  mockRequest.body = body
  mockRequest.headers = headers
  mockRequest.remoteAddress = "127.0.0.1"
  mockRequest.responseHeaders = @[]

  let mockReqPtr = addr mockRequest

  handler(mockReqPtr, response)

  result = response

proc debugResponse*(response: MockResponse): string =
  result = "HTTP/1.1 " & $response.code & " " & statusText(response.code) & "\c\L"
  for (k, v) in response.headers:
    result &= k & ": " & v & "\c\L"
  result &= "\c\L"
  result &= response.body