# Hunos Code Review

**Reviewer:** Kilo
**Date:** 2026-05-01
**Last Updated:** 2026-05-01 (Round 2)
**Scope:** Full codebase — `src/`, `tests/`, `examples/`
**Total lines reviewed:** ~3,063 (2,176 src + 747 tests + 140 examples)

---

## Executive Summary

Hunos is a well-structured HTTP/1.1 + WebSocket server that successfully improves on Mummy in several areas (trie router, middleware, zero dependencies). The core architecture — single IO thread with epoll/select + worker thread pool — is sound and proven. The codebase is clean and readable.

Round 1 identified **3 bugs** (1 critical), **2 security concerns**, and several performance and correctness issues. **2 security/critical issues were fixed.**

Round 2 identified **6 additional issues** (3 bugs, 2 security/quality, 1 performance) and fixed all of them, plus 3 code quality improvements.

**Total: 9 new issues found and fixed in Round 2.**

---

## Fixed Issues

### ✅ BUG-2: CORS middleware modifies request headers instead of response headers (FIXED — Round 1)

**File:** `src/hunos/middleware.nim:43-50`, `src/hunos.nim:57,318-321`

**Problem:** CORS headers were being added to `request.headers` (request object) instead of response headers. When `request.respond()` was called, it used a separate `handlerHeaders` that didn't include the CORS headers.

**Fix:** Added `responseHeaders*: HttpHeaders` field to `RequestObj`. The `respond()` procedure now merges `request.responseHeaders` into the response headers before encoding.

---

### ✅ SEC-2: Weak request ID generation (FIXED — Round 1)

**File:** `src/hunos/middleware.nim:70-77`

**Problem:** Request ID was using `cast[uint64](request)` - the memory address of the Request object. This is predictable, not unique across restarts, and exposes heap allocation addresses.

**Fix:** Replaced with atomic counter `requestIdCounter.fetchAdd(1)`.

---

### ✅ BUG-4: requestIdMiddleware sets X-Request-Id only on request.headers (FIXED — Round 2)

**File:** `src/hunos/middleware.nim:72-78`

**Problem:** The `requestIdMiddleware` set the generated X-Request-Id on `request.headers` (incoming request headers) but NOT on `request.responseHeaders`. This meant the X-Request-Id was available to downstream handlers for logging, but was **never sent back to the client** in the response.

**Fix:** Now sets X-Request-Id on both `request.headers` (for handler access) and `request.responseHeaders` (for client response). If the client already sent an X-Request-Id, it's forwarded to the response.

```nim
proc requestIdMiddleware*: MiddlewareProc =
  return proc(request: Request, next: proc()) {.gcsafe.} =
    let existingId = request.headers["X-Request-Id"]
    if existingId != "":
      request.responseHeaders["X-Request-Id"] = existingId
    else:
      let id = requestIdCounter.fetchAdd(1)
      let idStr = $id
      request.headers["X-Request-Id"] = idStr
      request.responseHeaders["X-Request-Id"] = idStr
    next()
```

---

### ✅ BUG-5: encodeHeaders hardcodes HTTP/1.1 (FIXED — Round 2)

**File:** `src/hunos/internal.nim:50-114`

**Problem:** `encodeHeaders()` always wrote "HTTP/1.1" in the response status line, regardless of the client's HTTP version. HTTP/1.0 clients received HTTP/1.1 responses. While RFC 2616 allows this, strict HTTP/1.0 clients may not handle HTTP/1.1 responses correctly.

**Fix:** Added `httpVersion: HttpVersion = Http11` parameter to `encodeHeaders()`. The `respond()` proc now passes `request.httpVersion` through.

```nim
proc encodeHeaders*(
  statusCode: int,
  headers: HttpHeaders,
  httpVersion: HttpVersion = Http11
): string {.raises: [], gcsafe.} =
  # ...
  let versionStr = if httpVersion == Http10: "HTTP/1.0" else: "HTTP/1.1"
```

---

### ✅ BUG-6: encodeFrameHeader uses assert() stripped in release builds (FIXED — Round 2)

**File:** `src/hunos/internal.nim:116-120`

**Problem:** `encodeFrameHeader()` used `assert (opcode and 0b11110000) == 0` to validate the WebSocket opcode. In Nim, `assert` is removed in release builds (`-d:release`), meaning invalid opcodes could silently produce corrupt WebSocket frames in production.

**Fix:** Replaced `assert` with runtime masking: `let opcode = opcode and 0b00001111'u8`. This ensures the upper bits are always cleared, making the function safe regardless of build mode.

---

### ✅ SEC-3: URL-encoded directory traversal bypass in static files (FIXED — Round 2)

**File:** `src/hunos/staticfiles.nim:53-69`

**Problem:** The `serveFile()` function checked for `".." in relPath` but did NOT URL-decode the path first. An attacker could send `%2e%2e` (URL-encoded `..`) which would bypass the substring check. While `normalizedPath()` provides a second layer of defense, the `..` check was incomplete.

**Fix:** Added `decodeUrlPath()` function that decodes `%XX` sequences before security checks. The path is now decoded before the `..` substring check and `normalizedPath()` validation.

```nim
proc decodeUrlPath(path: string): string =
  result = newString(path.len)
  var i = 0
  var o = 0
  while i < path.len:
    if path[i] == '%' and i + 2 < path.len:
      let hex = path[i + 1 .. i + 2]
      var code: int
      try:
        code = parseHexInt(hex)
      except ValueError:
        result[o] = path[i]
        inc o
        inc i
        continue
      result[o] = chr(code)
      inc o
      i += 3
    else:
      result[o] = path[i]
      inc o
      inc i
  result.setLen(o)
```

---

### ✅ PERF-5: Rate limiter inefficient seq copy (FIXED — Round 2)

**File:** `src/hunos/ratelimit.nim:16-34`

**Problem:** `isAllowed()` copied the timestamp sequence twice per request:
1. `var timestamps = limiter.clients[clientIP]` — full copy
2. Building a new `valid` seq and reassigning — another copy

This created unnecessary allocations under load.

**Fix:** Replaced with in-place filtering using a write index. Added `close()` proc for proper lock cleanup.

```nim
proc isAllowed*(limiter: var RateLimiter, clientIP: string): bool =
  let now = epochTime()
  withLock limiter.lock:
    if clientIP notin limiter.clients:
      limiter.clients[clientIP] = @[]
    var timestamps = limiter.clients.mgetOrPut(clientIP, @[])
    var writeIdx = 0
    for readIdx in 0 ..< timestamps.len:
      if now - timestamps[readIdx] < limiter.windowSize:
        timestamps[writeIdx] = timestamps[readIdx]
        inc writeIdx
    timestamps.setLen(writeIdx)
    if writeIdx >= limiter.maxRequests:
      return false
    timestamps.add(now)
    return true

proc close*(limiter: var RateLimiter) =
  deinitLock(limiter.lock)
```

---

### ✅ QUAL-6: Bench tests use bare `except` clauses (FIXED — Round 2)

**Files:** `tests/bench_scaling.nim`, `tests/bench_latency.nim`, `tests/bench_memory.nim`

**Problem:** Bare `except:` catches ALL exceptions including system exceptions like `OutOfMemError` and `StackOverflowError`. This masks real failures during benchmarks.

**Fix:** Replaced with `except Exception:` or `except ValueError:` as appropriate.

---

### ✅ QUAL-7: Test imports use self-referencing relative path (FIXED — Round 2)

**Files:** `tests/test_concurrent.nim`, `tests/bench_scaling.nim`, `tests/bench_latency.nim`

**Problem:** Tests imported `../tests/wrk_shared` which is a self-referencing path (going up to parent then back into the same directory). This is fragile and confusing.

**Fix:** Changed to `./wrk_shared` (same-directory import).

---

## Remaining Issues

### BUG-1: Header value trailing whitespace (CLAIM: NOT A BUG)

**File:** `src/hunos.nim:800`

The code review claimed line 800 had `leftLen > 0` but should have `rightLen > 0`. Upon inspection, the current code already uses `rightLen`:

```nim
while rightLen > 0 and
  dataEntry.recvBuf[rightStart + rightLen - 1] in whitespace:
  dec rightLen
```

This appears correct. The original bug report may have had incorrect line numbers.

**Status:** Not a bug (or already fixed)

---

### BUG-3: `test_core.nim` trie test doesn't test the actual Router

**File:** `tests/test_core.nim:21-93`

The trie router test block creates its own `TestRouter` and `TestTrieNode` types that duplicate the router logic instead of testing the actual `Router` from `hunos/router`. If the real router has a bug, this test won't catch it.

**Status:** Open - needs test rewrite

---

### SEC-1: Directory traversal check is redundant (LOW PRIORITY)

**File:** `src/hunos/staticfiles.nim`

After the Round 2 fix adding URL decoding, the `".." in relPath` check is now effective but still redundant with the `normalizedPath()` check. Both are defense-in-depth.

**Status:** Open - acceptable as defense-in-depth

---

## Performance Issues

### PERF-1: No response compression

**File:** `src/hunos.nim:317-320`

Mummy automatically compresses responses > 860 bytes with gzip/deflate. Hunos has no compression.

**Status:** Open - known limitation, documented in code

### PERF-2: Rate limiter copies timestamp array on every request (FIXED)

**Status:** Fixed in Round 2 — now uses in-place filtering.

### PERF-3: Rate limiter has no automatic cleanup

**File:** `src/hunos/ratelimit.nim`

`cleanup()` proc exists but must be called manually.

**Status:** Open

### PERF-4: Static file serving reads entire file into memory

**File:** `src/hunos/staticfiles.nim:74`

**Status:** Open - known limitation

---

## Code Quality Issues

### QUAL-1: Dead code in router.nim (NOT FOUND)

**Status:** The `isPartialWildcard` and `partialWildcardMatches` procs mentioned in the original review do not exist in the codebase. No action needed.

### QUAL-2: `WarnLevel` defined but never used

**File:** `src/hunos/common.nim:10`

**Status:** Open - info level

### QUAL-3: `sha1Block` uses `block` keyword as variable name (FIXED — Round 2)

**File:** `src/hunos/sha.nim:72`

`block` is a reserved keyword in Nim 2.x. The variable was renamed to `chunk`.

**Status:** Fixed

### QUAL-4: `base64Encode` is hardcoded for 20-byte input

**File:** `src/hunos/sha.nim:88`

**Status:** Open - info level

### QUAL-5: Benchmark comments in Bulgarian

**Files:** `tests/bench_*.nim`

**Status:** Open - info level

### QUAL-8: loggingMiddleware silent when logHandler=nil

**File:** `src/hunos/middleware.nim:57-70`

When `logHandler` is not provided, `loggingMiddleware` silently discards all log messages. The middleware can't access `request.server.log()` because `server` is a private field on `RequestObj`.

**Status:** Open - requires either exporting `server` field or adding a public `log()` accessor for `Request`

---

### ✅ COMPAT-1..5: Nim 2.2.10 compatibility fixes (FIXED — Round 2)

The codebase was developed on an older Nim version and had 5 issues preventing compilation on Nim 2.2.10:

1. **`parseUrl` tuple return type** (`src/hunos.nim:166`): `tuple[path: string, query: seq[(string, string)]]` caused a parser error. Fixed with `QueryParam` type alias.
2. **Missing `std/bitops` import** (`src/hunos/sha.nim`): `rotateLeftBits` is no longer in the prelude. Added explicit `import std/bitops`.
3. **`block` keyword as variable** (`src/hunos/sha.nim:72`): Renamed to `chunk` (covered by QUAL-3).
4. **Missing `split` import** (`src/hunos.nim:13`): `strutils.split` wasn't in the explicit import list.
5. **`test_core.nim` inline import** (`tests/test_core.nim:89`): `import` inside a `block:` is not allowed. Moved to top level.
6. **`test_core.nim` uninitialized Router** (`tests/test_core.nim:4`): `var router: Router` leaves `root` as nil → SIGSEGV. Fixed to `var router = newRouter()`.

**Status:** All fixed

---

## Missing Features (Compared to Mummy)

| Feature | Mummy | Hunos | Status | Notes |
|---------|-------|-------|--------|-------|
| Gzip/deflate compression | ✅ | ❌ | Open | Mummy auto-compresses responses > 860 bytes via `zippy`. Hunos has placeholder comment (`src/hunos.nim:317-320`) but no implementation. |
| Multipart form parsing | ✅ | ❌ | Open | Mummy has `mummy/multipart.nim` with `decodeMultipart()`. Hunos has no equivalent. |
| Partial wildcards (`*.json`) | ✅ | ❌ | Open | Mummy router supports `*`, `/*`, `/page_*`, `/*_something_*`. Hunos only supports `@param` and `**`. |
| Named path parameters | ✅ | ✅ | — | Both support `@id` style params. Hunos uses trie, Mummy uses linear scan. |
| HTTP pipelining detection | ✅ | ✅ | — | Both log a debug warning when data arrives before previous response is sent. Identical behavior. |
| File logger | ❌ | ❌ | — | Neither has a built-in file logger. Both only expose a `LogHandler` callback. Can be added externally. |

### Details

**Compression:** Adding gzip/deflate would require either adding `zippy` as an optional dependency or implementing deflate internally. The placeholder in `respond()` is ready for integration.

**Multipart:** Mummy's `decodeMultipart()` returns `seq[MultipartEntry]` with lazy `(start, last)` slices into the request body. A Hunos equivalent could live in `hunos/multipart.nim` and avoid copying large uploads.

**Router wildcards:** Mummy's `*` wildcard matches 0+ characters excluding `/`. Valid patterns: `/api/*.json`, `/page_*`, `/*_something_*`. Hunos router only has exact segment matches, `@param` (single segment), and `**` (multi-segment). Adding `*` would require updating `addRoute()` and `matchNode()` in `router.nim`.

---

## Recommendations (Priority Order)

1. **Fix BUG-3** (test the real Router) — rewrite test_core.nim trie block
2. **Add compression** — optional zippy dep or built-in deflate
3. **Add multipart parsing** — required for form file uploads
4. **Improve test coverage** — unit tests for middleware, rate limiter, static files
5. **Add automatic rate limiter cleanup** — background thread or periodic task
6. **QUAL-8: Export server field or add Request.log() accessor** — enables middleware logging
7. **Optional: translate comments to English** — for broader adoption

---

## Positive Observations

- **Clean architecture.** The separation into modules (common, internal, router, middleware, sha, ratelimit, staticfiles) is well-organized.
- **Zero dependencies.** Implementing SHA1, Base64, HTTP headers, and URL parsing internally eliminates supply chain risk.
- **Proven IO model.** The epoll + worker pool pattern is the same as Mummy, which has been production-tested with 100k+ concurrent WebSocket connections.
- **Trie router is correct.** The backtracking logic for path parameters is properly implemented.
- **Good error handling in worker proc.** Uncaught handler exceptions result in a 500 response instead of crashing the server.
- **Thread-safe WebSocket send/close.** The send queue with lock + event trigger pattern is correct and efficient.
- **Defense-in-depth for static files.** After Round 2 fixes, static file serving has URL decoding + substring check + normalizedPath validation (3 layers).
