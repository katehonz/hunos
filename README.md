# Hunos

High-performance, multi-threaded HTTP/1.1 and WebSocket server for Nim.

Hunos is built on the proven single-IO-thread + worker-pool architecture, with significant improvements over [Mummy](https://github.com/guzba/mummy) in routing performance, developer ergonomics, and built-in features.

## Table of Contents

- [Key Improvements Over Mummy](#key-improvements-over-mummy)
- [Architecture](#architecture)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Routing](#routing)
- [Middleware](#middleware)
- [WebSocket](#websocket)
- [Compression](#compression)
- [Multipart Form Parsing](#multipart-form-parsing)
- [Static File Serving](#static-file-serving)
- [Rate Limiting](#rate-limiting)
- [Benchmarks](#benchmarks)
- [Building](#building)
- [Testing](#testing)
- [Project Structure](#project-structure)
- [License](#license)

## Key Improvements Over Mummy

| Feature | Mummy | Hunos |
|---------|-------|-------|
| **Router algorithm** | O(routes × parts) linear scan | O(path_length) trie |
| **Middleware** | None | Composable pipeline with CORS, logging, recovery |
| **Compression** | zippy (external) | zippy (optional, `-d:hunosNoCompression` to disable) |
| **Multipart parsing** | Built-in | Built-in (`hunos/multipart`) |
| **Rate limiting** | None | Thread-safe sliding window |
| **Static files** | None | MIME detection, traversal protection, URL decoding |
| **Status codes** | Numeric only | Human-readable messages |
| **SHA1 / Base64** | External crates | Built-in implementation |
| **Nim compatibility** | 2.0+ | 2.0+ (tested on 2.2.10) |

## Architecture

```
┌─────────────────────────────────────────────┐
│                Main Thread                   │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │ Accept Loop  │  │  Epoll / Select Loop │  │
│  └─────────────┘  └──────────────────────┘  │
└─────────────────┬───────────────────────────┘
                  │ task queue
    ┌─────────────┼─────────────┐
    ▼             ▼             ▼
┌────────┐  ┌────────┐  ┌────────┐
│Worker 1│  │Worker 2│  │Worker N│
│        │  │        │  │        │
│Handler │  │Handler │  │Handler │
│+ Trie  │  │+ Trie  │  │+ Trie  │
│  Match │  │  Match │  │  Match │
└────────┘  └────────┘  └────────┘
```

- **Single IO thread** — all socket read/write via epoll (Linux) or select (cross-platform), non-blocking.
- **Worker thread pool** — `max(countProcessors() * 10, 1)` threads by default.
- **Trie router** — O(k) matching where k = number of path segments, independent of route count.
- **Shared-nothing between workers** — each request is dispatched to one worker; shared immutable data (model weights, config) is read-only and lock-free under ORC.

## Installation

```bash
nimble install hunos
```

Or add to your `.nimble` file:

```nim
requires "hunos >= 1.1.0"
```

**Requirements:** Nim >= 2.0.0, `--threads:on`, `--mm:orc` (or `--mm:arc` / `--mm:atomicArc`).

## Quick Start

### Hello World

```nim
import hunos

proc handler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "Hello, World!")

let server = newServer(handler)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
```

```bash
nim c --threads:on --mm:orc -d:release -r examples/basic.nim
```

### Router with Path Parameters

```nim
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

var router = newRouter()
router.get("/", indexHandler)
router.get("/user/@id", userHandler)

let server = newServer(router)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
```

### WebSocket Chat

```nim
import hunos, hunos/router, std/locks, std/sets

var
  lock: Lock
  clients: HashSet[WebSocket]

initLock(lock)

proc upgradeHandler(request: Request) =
  let websocket = request.upgradeToWebSocket()
  websocket.send("Welcome!")

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent, message: Message) =
  case event:
  of OpenEvent:
    {.gcsafe.}:
      withLock lock:
        clients.incl(websocket)
  of MessageEvent:
    {.gcsafe.}:
      withLock lock:
        for client in clients:
          client.send(message.data)
  of CloseEvent:
    {.gcsafe.}:
      withLock lock:
        clients.excl(websocket)
  of ErrorEvent:
    discard

var router = newRouter()
router.get("/ws", upgradeHandler)

let server = newServer(router, websocketHandler)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
```

### Middleware Stack

```nim
import hunos, hunos/router, hunos/middleware

proc apiHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"message": "Hello"}""")

var router = newRouter()
router.get("/api", apiHandler)

var stack = newMiddlewareStack(router)
stack.use(corsMiddleware())
stack.use(loggingMiddleware())
stack.use(requestIdMiddleware())
stack.use(recoveryMiddleware())

let server = newServer(stack)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
```

## API Reference

### Server

```nim
proc newServer*(
  handler: RequestHandler,
  websocketHandler: WebSocketHandler = nil,
  logHandler: LogHandler = nil,
  workerThreads = max(countProcessors() * 10, 1),
  maxHeadersLen = 8 * 1024,      # 8 KB
  maxBodyLen = 1024 * 1024,       # 1 MB
  maxMessageLen = 64 * 1024,      # 64 KB
  tcpNoDelay = true
): Server

proc serve*(server: Server, port: Port, address = "localhost")
proc close*(server: Server)
proc waitUntilReady*(server: Server, timeout: float = 10)
proc log*(server: Server, level: LogLevel, args: varargs[string])
```

### Request

```nim
type Request = ptr RequestObj
RequestObj = object
  httpVersion*: HttpVersion      # Http10 or Http11
  httpMethod*: string            # "GET", "POST", etc.
  uri*: string                   # Raw URI from request line
  path*: string                  # Decoded URI path
  queryParams*: seq[(string, string)]
  pathParams*: PathParams        # Populated by router
  headers*: HttpHeaders          # Case-insensitive key-value pairs
  body*: string
  remoteAddress*: string
  server*: Server                # Server instance
  responseHeaders*: HttpHeaders  # Merged into response by respond()

proc respond*(request: Request, statusCode: int,
              headers: HttpHeaders = @[], body: string = "")
proc upgradeToWebSocket*(request: Request): WebSocket
proc responded*(request: Request): bool
proc log*(request: Request, level: LogLevel, args: varargs[string])
```

### HttpHeaders

```nim
type HttpHeaders = seq[(string, string)]

proc `[]`*(headers: HttpHeaders, key: string): string
proc `[]=`*(headers: var HttpHeaders, key, value: string)
proc contains*(headers: HttpHeaders, key: string): bool
proc headerContainsToken*(headers: HttpHeaders, key, token: string): bool
```

### WebSocket

```nim
proc send*(websocket: WebSocket, data: string, kind = TextMessage)
proc close*(websocket: WebSocket)
```

## Routing

Routes are registered via the `Router` object from `hunos/router`:

```nim
import hunos/router

var router = newRouter()
router.get("/path", handler)
router.post("/path", handler)
router.put("/path", handler)
router.delete("/path", handler)
router.head("/path", handler)
router.options("/path", handler)
router.patch("/path", handler)
```

### Route Patterns

| Pattern | Matches | Example |
|---------|---------|---------|
| `/` | Root only | `/` |
| `/users` | Exact segment | `/users` |
| `/user/@id` | Named parameter | `/user/42`, `/user/abc` |
| `/files/**` | Multi-segment wildcard | `/files/a/b/c` |

### Custom Error Handlers

```nim
router.notFoundHandler = proc(request: Request) =
  request.respond(404, headers, "Custom 404")

router.methodNotAllowedHandler = proc(request: Request) =
  request.respond(405, headers, "Custom 405")

router.errorHandler = proc(request: Request, e: ref Exception) =
  request.respond(500, headers, "Custom 500")
```

### Converter

`Router` has an implicit converter to `RequestHandler`, so you can pass it directly to `newServer`:

```nim
let server = newServer(router)  # Router auto-converts to RequestHandler
```

## Middleware

The middleware system uses a pipeline pattern where each middleware calls `next()` to pass control to the next middleware or the final handler.

### Built-in Middleware

| Middleware | Description |
|-----------|-------------|
| `corsMiddleware()` | Adds CORS headers, handles OPTIONS preflight |
| `loggingMiddleware()` | Logs request method, URI, duration (uses server logger by default) |
| `requestIdMiddleware()` | Adds X-Request-Id to request and response headers |
| `recoveryMiddleware()` | Catches unhandled exceptions, returns 500 |

### Custom Middleware

```nim
proc authMiddleware(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
  let token = request.headers["Authorization"]
  if token == "":
    request.respond(401)
    return  # Do NOT call next()
  next()    # Pass to next middleware / handler
```

### Middleware Stack

```nim
var stack = newMiddlewareStack(handler)
stack.use(corsMiddleware())
stack.use(authMiddleware)
stack.use(loggingMiddleware())

# MiddlewareStack also converts to RequestHandler
let server = newServer(stack)
```

## WebSocket

WebSocket connections are established by upgrading an HTTP request:

1. Client sends HTTP request with `Upgrade: websocket` headers.
2. Handler calls `request.upgradeToWebSocket()` to get a `WebSocket` handle.
3. Future events are dispatched to the `websocketHandler` callback.

### WebSocket Events

| Event | Description |
|-------|-------------|
| `OpenEvent` | Connection established |
| `MessageEvent` | Message received (text, binary, ping, pong) |
| `ErrorEvent` | Connection error (e.g., network failure) |
| `CloseEvent` | Connection closed |

### Message Types

| Kind | Description |
|------|-------------|
| `TextMessage` | UTF-8 text frame |
| `BinaryMessage` | Binary frame |
| `Ping` | Ping control frame |
| `Pong` | Pong control frame |

### Thread Safety

WebSocket `send()` and `close()` are thread-safe and can be called from any thread. WebSocket events for the same connection are dispatched serially — a handler will not be called again for the same connection until it returns.

## Compression

Hunos automatically compresses HTTP responses using gzip or deflate when:

1. The response body exceeds 860 bytes
2. The client sends an `Accept-Encoding: gzip` or `Accept-Encoding: deflate` header
3. The response doesn't already have a `Content-Encoding` header

Compression uses [zippy](https://github.com/guzba/zippy) and is enabled by default. To disable:

```bash
nim c --threads:on --mm:orc -d:hunosNoCompression -d:release your_app.nim
```

## Multipart Form Parsing

Parse `multipart/form-data` requests (file uploads, HTML forms):

```nim
import hunos, hunos/multipart

proc uploadHandler(request: Request) =
  let contentType = request.headers["Content-Type"]
  if "multipart/form-data" notin contentType:
    request.respond(400, body = "Expected multipart/form-data")
    return

  let data = decodeMultipart(request.body, contentType)

  # Get text field value
  let username = data.getField("username")

  # Get uploaded file
  let file = data.getFile("avatar")
  if file.filename.len > 0:
    echo "File: ", file.filename
    echo "Type: ", file.contentType
    echo "Size: ", file.body.len
    writeFile("uploads/" & file.filename, file.body)

  request.respond(200, body = "Upload successful")
```

### Multipart API

```nim
type
  MultipartEntry = object
    name*: string           # Field name from Content-Disposition
    filename*: string       # Filename (empty for text fields)
    contentType*: string    # Content-Type header value
    headers*: seq[(string, string)]  # All part headers
    body*: string           # Part body content
    bodyStart*: int         # Offset into original body
    bodyLen*: int           # Length of part body

  MultipartData = object
    entries*: seq[MultipartEntry]
    body*: string           # Original request body

proc decodeMultipart*(body: string, contentType: string): MultipartData
proc getField*(data: MultipartData, name: string): string
proc getFile*(data: MultipartData, name: string): MultipartEntry
proc getFields*(data: MultipartData, name: string): seq[string]
proc hasField*(data: MultipartData, name: string): bool
```

## Static File Serving

```nim
import hunos/staticfiles

let config = newStaticConfig(
  root = "./public",
  urlPrefix = "/static",
  indexFile = "index.html",
  maxAge = 3600
)

proc staticHandler(request: Request) =
  let entry = serveFile(config, request.uri)
  if entry.filePath.len > 0:
    var headers: HttpHeaders
    headers["Content-Type"] = entry.contentType
    headers["Cache-Control"] = "max-age=" & $config.maxAge
    headers["Content-Length"] = $entry.content.len
    request.respond(200, headers, entry.content)
  else:
    request.respond(404)
```

**Security:** Directory traversal attempts (`..` in path, including URL-encoded `%2e%2e`) are rejected. Paths are validated with both substring check and `normalizedPath()`.

**MIME types:** 20+ types built-in including HTML, CSS, JS, JSON, images, fonts, WASM.

## Rate Limiting

```nim
import hunos/ratelimit

var limiter = newRateLimiter(
  windowSize = 60.0,   # 60-second sliding window
  maxRequests = 100     # 100 requests per window per IP
)

proc rateLimitedHandler(request: Request) =
  if not limiter.isAllowed(request.remoteAddress):
    var headers: HttpHeaders
    headers["Retry-After"] = "60"
    request.respond(429, headers, "Too Many Requests")
    return
  # Normal handling...

# Clean up expired entries periodically
limiter.cleanup()

# Release lock when done
limiter.close()
```

**Thread safety:** The rate limiter uses a lock internally and is safe to call from worker threads.

**Cleanup:** Call `limiter.cleanup()` periodically (e.g., from a timer) to free memory from expired IP entries. Call `limiter.close()` to release the lock when the limiter is no longer needed.

## Benchmarks

### wrk Benchmark

The standard benchmark comparable with Mummy and other Nim HTTP servers:

```bash
# Terminal 1: start server
nim c --threads:on --mm:orc -d:release -r tests/wrk_hunos.nim

# Terminal 2: run wrk
wrk -t10 -c100 -d10s http://localhost:8080
```

Each request simulates 10ms of compute work (like an AI inference call).

### Scaling Test

Measures throughput at 1, 2, 4, 8, 16, and 32 worker threads:

```bash
nim c --threads:on --mm:orc -d:release -r tests/bench_scaling.nim
```

Expected results on an 8-core machine:

```
Workers | Requests/sec | Scaling factor
      1 |        ~1200 | 1.00x
      2 |        ~2350 | 1.96x
      4 |        ~4600 | 3.83x
      8 |        ~9100 | 7.58x
     16 |        ~9400 | 7.83x  (plateau at physical cores)
```

### Latency Benchmark

Measures P50/P95/P99 latency with 10ms simulated compute:

```bash
nim c --threads:on --mm:orc -d:release -r tests/bench_latency.nim
```

Expected: P50 ~10.2ms, P95 ~13.5ms, P99 ~18ms.

### Memory Sharing Benchmark (MoE Simulation)

Demonstrates read-only sharing of model parameters across threads — the pattern used for MoE inference:

```bash
nim c --threads:on --mm:orc -d:release -r tests/bench_memory.nim
```

Key observation: 8 threads share the same physical memory pages for model parameters. RSS ≈ model size, not model_size × threads.

### Comparison: Hunos vs AsyncHttpServer

| Metric | AsyncHttpServer | Hunos (8 workers) |
|--------|----------------|-------------------|
| Throughput | ~8,000 req/s | ~9,500 req/s |
| P50 Latency | ~12ms | ~10.2ms |
| Concurrent heavy requests | 1 (blocked event loop) | N (parallel workers) |
| Thread safety | Single-threaded | Full multi-thread |

## Building

```bash
# Debug build
nim c --threads:on --mm:orc examples/basic.nim

# Release build
nim c --threads:on --mm:orc -d:release examples/basic.nim

# With all optimizations
nim c --threads:on --mm:orc -d:release --passC:"-flto" --passL:"-flto" examples/basic.nim

# Without compression (zero external dependencies)
nim c --threads:on --mm:orc -d:hunosNoCompression -d:release examples/basic.nim
```

## Testing

```bash
# Unit tests (SHA1, Base64, HttpHeaders, PathParams, trie router)
nim c --threads:on --mm:orc --path:src -r tests/test_core.nim

# Router edge cases (params, wildcards, error handlers, all HTTP methods)
nim c --threads:on --mm:orc --path:src -r tests/test_router.nim

# Middleware pipeline (CORS, logging, request ID, recovery)
nim c --threads:on --mm:orc --path:src -r tests/test_middleware.nim

# Rate limiter (sliding window, IP isolation, cleanup)
nim c --threads:on --mm:orc --path:src -r tests/test_ratelimit.nim

# Static files (MIME types, traversal protection, URL prefix)
nim c --threads:on --mm:orc --path:src -r tests/test_staticfiles.nim

# Multipart form parsing (text fields, file uploads, boundaries)
nim c --threads:on --mm:orc --path:src -r tests/test_multipart.nim

# Concurrency correctness (16 threads × 100 requests)
nim c --threads:on --mm:orc -d:release -r tests/test_concurrent.nim

# Scaling benchmark
nim c --threads:on --mm:orc -d:release -r tests/bench_scaling.nim

# Latency benchmark
nim c --threads:on --mm:orc -d:release -r tests/bench_latency.nim

# Memory sharing benchmark
nim c --threads:on --mm:orc -d:release -r tests/bench_memory.nim
```

## Project Structure

```
hunos/
├── src/
│   ├── hunos.nim              # Core server (types, IO loop, workers, HTTP/WS parsing)
│   └── hunos/
│       ├── common.nim          # Error types, log levels, PathParams
│       ├── compress.nim        # gzip/deflate compression (wraps zippy)
│       ├── internal.nim        # HttpHeaders, encoding, parsing helpers
│       ├── multipart.nim       # multipart/form-data parser
│       ├── router.nim          # Trie-based router
│       ├── middleware.nim       # Middleware pipeline + built-in middleware
│       ├── sha.nim             # SHA1 + Base64 (for WebSocket handshake)
│       ├── ratelimit.nim       # Sliding-window rate limiter
│       └── staticfiles.nim     # Static file serving with MIME detection
├── examples/
│   ├── basic.nim
│   ├── router_example.nim
│   ├── websocket_example.nim
│   └── middleware_example.nim
├── tests/
│   ├── test_core.nim           # SHA1, Base64, headers, path params, router
│   ├── test_router.nim         # Router edge cases (10 tests)
│   ├── test_middleware.nim      # Middleware pipeline (6 tests)
│   ├── test_ratelimit.nim      # Rate limiter (5 tests)
│   ├── test_staticfiles.nim    # Static files (8 tests)
│   ├── test_multipart.nim      # Multipart parsing (7 tests)
│   ├── test_concurrent.nim     # Concurrency correctness
│   ├── bench_scaling.nim       # Throughput scaling benchmark
│   ├── bench_latency.nim       # Latency percentile benchmark
│   ├── bench_memory.nim        # Memory sharing benchmark (MoE)
│   ├── wrk_hunos.nim           # wrk load generator target
│   ├── wrk_asynchttpserver.nim # wrk comparison target
│   └── wrk_shared.nim          # Shared constants
├── hunos.nimble
├── config.nims
├── CODE_REVIEW.md
└── README.md
```

## License

MIT
