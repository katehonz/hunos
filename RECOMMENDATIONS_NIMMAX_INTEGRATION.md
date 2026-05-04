# Препоръки за Hunos като Backend на NimMax Framework

## Кратък отговор: Може ли Hunos да замести asynchttpserver?

**Да, но със значителни архитектурни промени.** Hunos и NimMax са фундаментално различни:

| Аспект | NimMax (asynchttpserver) | Hunos |
|--------|--------------------------|-------|
| **Модел** | Single-threaded async/await | Multi-threaded sync (IO thread + worker pool) |
| **Handler signature** | `proc(ctx: Context): Future[void] {.async.}` | `proc(request: Request) {.gcsafe.}` |
| **Middleware** | Onion model с `await switch(ctx)` | Pipeline с `next()` callback |
| **Router** | Линеен скан със specificity сортиране | Trie-based O(k) matching |
| **Обект** | `Context` обгръща `Request` + `Response` | Директен достъп до `Request` |
| **Thread safety** | Не е нужна (един event loop) | Задължителна (множество worker-и) |

Ако замениш asynchttpserver с Hunos в NimMax, **всички async хендлъри ще блокират worker thread-овете** при DB заявки, HTTP извиквания и друг IO. Това ще намали производителността драстично при IO-bound workloads.

---

## 1. Архитектурни разлики, които трябва да се преодолеят

### 1.1 Async → Sync мапиране

NimMax хендлърите използват `Future[void]` и `await`. За да работят в Hunos:

**Опция A: Thread pool за async операции** (препоръчително)
```nim
type
  AsyncContext* = ref object
    request*: Request
    response*: Response
    # ... други полета от Context
    
proc runAsyncHandler*(handler: HandlerAsync, ctx: AsyncContext) {.gcsafe.} =
  # Стартирай async хендлъра в отделен thread pool,
  # за да не блокираш Hunos worker-ите
```

**Опция B: Пренапиши NimMax хендлърите като sync**
Това е огромна работа и чупи backward compatibility.

**Опция C: Хибриден модел**
Hunos worker thread-овете обработват само HTTP парсинга и routing, а за handler изпълнението се ползва отделен async пул (като в Go с goroutines).

### 1.2 Context vs Request

NimMax използва `Context` като централен обект, който съдържа:
- `request` (Request)
- `response` (Response)
- `session` (Session)
- `ctxData` (Table за custom данни)
- `middlewares` и `middlewareIdx`
- `gScope` (global scope с настройки и рутер)

Hunos работи директно с `Request`, който има `responseHeaders` и `respond()`.

**Препоръка:** Създай HunosContext, който обгръща Request и добавя недостигащите полета.

### 1.3 Middleware модели

NimMax (Onion model):
```nim
proc myMiddleware(ctx: Context): Future[void] {.async.} =
  # преди handler
  await switch(ctx)  # извиква следващ middleware/handler
  # след handler
```

Hunos (Pipeline model):
```nim
proc myMiddleware(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
  # преди handler
  next()  # извиква следващ middleware/handler
  # след handler
```

Моделите са еквивалентни, но Hunos middleware-ът няма достъп до response след `next()`, ако handler-ът вече е извикал `respond()`. NimMax пази `Response` отделно и го изпраща еднократно в края.

---

## 2. Конкретни подобрения, необходими в Hunos

### 2.1 Добави Response обект (Критично)

```nim
type
  Response* = object
    code*: int
    headers*: HttpHeaders
    body*: string
    
proc respond*(request: Request, response: Response) =
  request.respond(response.code, response.headers, response.body)
```

Това позволява middleware да модифицира response след извикване на handler-а.

### 2.2 Graceful Shutdown

NimMax има елегантно graceful shutdown с draining на активни заявки. Hunos няма такова.

```nim
proc shutdown*(server: Server, timeout: int = 30) =
  server.serving.store(false)
  # Спри да приемаш нови connections
  # Изчакай активни заявки (timeout)
  # Затвори socket-ите
```

### 2.3 Typed Path Parameters (като NimMax)

NimMax предоставя:
```nim
let id = ctx.getInt("id")        # Option[int]
let price = ctx.getFloat("price") # Option[float]
let active = ctx.getBool("active") # Option[bool]
```

Hunos има само `request.pathParams["id"]: string`. Добави:

```nim
proc getInt*(params: PathParams, key: string): Option[int] =
  try:
    result = some(parseInt(params[key]))
  except ValueError:
    result = none(int)

proc getFloat*(params: PathParams, key: string): Option[float] = ...
proc getBool*(params: PathParams, key: string): Option[bool] = ...
```

### 2.4 Cookie API

Hunos няма cookie parsing/setting. NimMax има пълноценно cookie API:
```nim
proc getCookie*(request: Request, name: string): string = ...
proc setCookie*(request: Request, name, value: string, path = "/", 
                maxAge = 0, httpOnly = false, secure = false, sameSite = "Lax") = ...
```

### 2.5 Session Management

Това е сложна функция, която Hunos няма. Нужно е:
- In-memory session store (thread-safe с locks)
- Signed-cookie backend (криптографски подписани cookies)
- Session middleware

### 2.6 CSRF Protection

NimMax има вграден CSRF middleware с токън генерация и валидация. За Hunos трябва да се добави аналог.

### 2.7 Form Validation

NimMax има 15+ валидатора с `Option[T]` връщане. Hunos няма нищо подобно.

### 2.8 Compression (Критично за производителност)

Според `CODE_REVIEW.md`, Hunos няма response compression. NimMax използва `zippy` за gzip/deflate. Добави:

```nim
proc compressionMiddleware*(minSize = 1024, level = clDefault): MiddlewareProc = ...
```

Hunos вече има `compress.nim` и `zippy` като зависимост — използвай ги.

### 2.9 Static File Serving подобрения

Hunos има `staticfiles.nim`, но според CODE_REVIEW:
- Чете целия файл в памет (лошо за големи файлове)
- Няма Range requests (NimMax ги поддържа)
- Няма ETag / If-None-Match / If-Modified-Since кеширане
- Няма `sendfile()` syscall за zero-copy

Добави:
```nim
proc serveFileStream*(config: StaticConfig, uri: string): StreamResponse = ...
proc generateETag*(filePath: string): string = ...
proc checkRangeRequest*(request: Request, fileSize: int): Option[(int, int)] = ...
```

### 2.10 Multipart Parsing подобрения

Hunos има `multipart.nim`, но провери дали:
- Поддържа streaming (без цялото тяло в RAM)
- Поддържа големи файлове (> 100MB)
- Има защита срещу boundary injection attacks

### 2.11 Rate Limiter подобрения

Има `ratelimit.nim`, но:
- Няма distributed backend (Redis) — NimMax също няма, но е добра идея
- Няма per-user limiting (само per-IP)
- Няма burst allowance (token bucket е по-добър от sliding window за API-та)

### 2.12 WebSocket подобрения

Hunos има WebSocket, но провери:
- Дали има per-message compression (RFC 7692)
- Дали има ping/pong heartbeat с timeout
- Дали поддържа binary frames адекватно

---

## 3. Предимства на Hunos, които NimMax няма (и трябва да запазиш)

### 3.1 Trie Router
NimMax използва линеен скан — O(routes × parts). Hunos е O(k) където k = брой сегменти. **Запази този router!**

### 3.2 Multi-threading
NimMax е single-threaded async. За CPU-bound заявки (криптография, ML inference, обработка на изображения) Hunos е драстично по-бърз. **Това е основното предимство.**

### 3.3 Zero Dependencies (почти)
Hunos е self-contained с SHA1, Base64, HTTP parsing. NimMax разчита на `zippy` и stdlib async. **Запази тази философия където е възможно.**

---

## 4. Препоръчителен план за интеграция

### Фаза 1: Адаптер слой (1-2 седмици)
Създай `nimmax_hunos.nim`, който имплементира NimMax `Context` API върху Hunos `Request`:

```nim
# nimmax_hunos.nim
import hunos, hunos/router
import std/options

type
  HunosContext* = ref object
    request*: Request
    response*: Response
    pathParams*: PathParams
    session*: Session  # ако се добави
    data*: Table[string, string]

proc getInt*(ctx: HunosContext, key: string): Option[int] = ...
proc html*(ctx: HunosContext, body: string) = ...
proc json*(ctx: HunosContext, data: JsonNode) = ...
# ... и т.н.
```

### Фаза 2: Async Bridge (2-3 седмици)
Ако NimMax хендлърите трябва да останат async, създай thread pool за async изпълнение:

```nim
type
  AsyncBridge = object
    pool: ThreadPool  # std/threadpool или custom

proc runAsync*(bridge: AsyncBridge, handler: HandlerAsync, ctx: HunosContext) =
  # Стартирай async event loop в отделен thread,
  # върни резултата в Hunos worker-а
```

### Фаза 3: Middleware адаптация (1 седмица)
Адаптирай NimMax middleware-ите за Hunos pipeline модела или обратно — имплементирай Onion model в Hunos.

### Фаза 4: Feature Parity (2-4 седмици)
Добави липсващите функции в Hunos (sessions, CSRF, validation, compression, cookie API).

---

## 5. Алтернатива: Хибриден подход (Препоръчително)

Вместо да заменяш asynchttpserver изцяло, използвай **Hunos за API endpoint-и** и **NimMax за async pages/WebSocket**:

```
NimMax (asynchttpserver)
├── /dashboard        → async pages с DB queries
├── /ws               → WebSocket (вече работи добре)
└── /api/*            → proxy към Hunos

Hunos (multi-threaded)
├── /api/inference    → CPU-heavy ML tasks
├── /api/compute      → blocking operations
└── /api/upload       → multipart file processing
```

Това ти дава най-доброто от двата свята без да пренаписваш целия NimMax.

---

## 6. Бързи Win-ове за Hunos (подобри веднага)

1. **Добави Response обект** — позволява post-handler middleware
2. **Добави `getInt`/`getFloat`/`getBool` за PathParams** — type safety
3. **Добави graceful shutdown** — production readiness
4. **Добави cookie API** — необходимо за сесии
5. **Активирай compression** — вече имаш `compress.nim`, свържи го с `respond()`
6. **Добави ETag/Range за static files** — значително подобрява performance
7. **Преведи коментарите на английски** — CODE_REVIEW споменава български коментари в benchmark-овете

---

## 7. Заключение

**Hunos е по-добър сървър от asynchttpserver** за CPU-bound и multi-core workloads, но **NimMax е по-пълен framework** със сесии, CSRF, валидация и async ecosystem.

Не е "drop-in replacement" — трябва да избереш:
- **Да пренапишеш NimMax върху Hunos** (3-6 месеца, чупи async API)
- **Да създадеш adapter слой** (1-2 месеца, компромиси с performance)
- **Да ползваш хибриден подход** (1-2 седмици, най-добър ROI)

Ако търсиш production-ready решение днес — **запази NimMax с asynchttpserver** и добави Hunos само за специфични CPU-heavy endpoint-и.
