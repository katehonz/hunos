# Hunos

High-performance, multi-threaded HTTP/1.1 and WebSocket server for Nim.

Hunos is built on the proven single-IO-thread + worker-pool architecture, with significant improvements over [Mummy](https://github.com/guzba/mummy) in routing performance, developer ergonomics, and built-in features — all with **zero external dependencies**.

## Table of Contents

- [Key Improvements Over Mummy](#key-improvements-over-mummy)
- [Architecture](#architecture)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Routing](#routing)
- [Middleware](#middleware)
- [WebSocket](#websocket)
- [Static File Serving](#static-file-serving)
- [Rate Limiting](#rate-limiting)
- [Benchmarks](#benchmarks)
- [Building](#building)
- [Testing](#testing)
- [License](#license)

## Key Improvements Over Mummy

| Feature | Mummy | Hunos |
|---------|-------|-------|
| **Router algorithm** | O(routes × parts) linear scan | O(path_length) trie |
| **Middleware** | None | Composable pipeline with CORS, logging, recovery |
| **External deps** | zippy, webby, crunchy | **None** (stdlib only) |
| **Rate limiting** | None | Thread-safe sliding window |
| **Static files** | None | MIME detection, traversal protection |
| **Status codes** | Numeric only | Human-readable messages |
| **SHA1 / Base64** | External crates | Built-in implementation |

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
requires "hunos >= 1.0.0"
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

var router: Router
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

var router: Router
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

var router: Router
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

proc respond*(request: Request, statusCode: int,
              headers: HttpHeaders = @[], body: string = "")
proc upgradeToWebSocket*(request: Request): WebSocket
proc responded*(request: Request): bool
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

var router: Router
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
| `loggingMiddleware()` | Logs request method, URI, duration |
| `requestIdMiddleware()` | Adds X-Request-Id header if not present |
| `recoveryMiddleware()` | Catches unhandled exceptions, returns 500 |

### Custom Middleware

```nim
proc authMiddleware(request: Request, next: proc()) {.gcsafe.} =
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

**Security:** Directory traversal attempts (`..` in path) are rejected.

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
```

**Thread safety:** The rate limiter uses a lock internally and is safe to call from worker threads.

**Cleanup:** Call `limiter.cleanup()` periodically (e.g., from a timer) to free memory from expired IP entries.

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
```

## Testing

```bash
# Unit tests (SHA1, Base64, trie router)
nim c --threads:on --mm:orc -r tests/test_core.nim

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
│       ├── internal.nim        # HttpHeaders, encoding, parsing helpers
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
│   ├── test_core.nim
│   ├── test_concurrent.nim
│   ├── bench_scaling.nim
│   ├── bench_latency.nim
│   ├── bench_memory.nim
│   ├── wrk_hunos.nim
│   ├── wrk_asynchttpserver.nim
│   └── wrk_shared.nim
├── hunos.nimble
├── config.nims
└── README.md
```

## License

MIT
