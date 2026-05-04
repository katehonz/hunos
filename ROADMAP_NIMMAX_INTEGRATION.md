# Пътна карта: Hunos → NimMax Integration

## Версия: 1.0
## Дата: 2026-05-04
## Цел: Постепенно превръщане на Hunos в production-ready backend за NimMax framework

---

## 1. Текущо състояние (какво е готово)

### ✅ Направено (commit `349e559`)

| Модул | Описание | Файл |
|-------|----------|------|
| **Response обект** | `Response` тип + `respond(request, response)` overload | `src/hunos/internal.nim` |
| **Typed Path Params** | `getInt`, `getFloat`, `getBool` → `Option[T]` | `src/hunos/common.nim` |
| **Cookie API** | `getCookie`, `setCookie` (headers & request) | `src/hunos.nim` |
| **Graceful Shutdown** | `shutdown(server, timeout)` с draining | `src/hunos.nim` |
| **Compression** | gzip/deflate авто-компресия в `respond()` | `src/hunos/compress.nim` |
| **Static Files v2** | ETag, Range, If-None-Match, If-Modified-Since | `src/hunos/staticfiles.nim` |
| **Session Management** | Thread-safe in-memory store + middleware | `src/hunos/sessions.nim` |
| **CSRF Protection** | Token middleware + `csrfTokenInput()` | `src/hunos/csrf.nim` |
| **Context API** | NimMax-style `Context` с typed params & helpers | `src/hunos/context.nim` |
| **Request.userData** | `pointer` поле за middleware данни | `src/hunos.nim` |
| **Тестови фиксове** | `test_concurrent`, `bench_latency`, `bench_scaling` | `tests/` |

### ✅ Всички unit тестове минават

```
test_concurrent  ✓
test_context     ✓
test_core        ✓
test_csrf        ✓
test_middleware  ✓
test_multipart   ✓
test_ratelimit   ✓
test_router      ✓
test_sessions    ✓
test_staticfiles ✓
```

### ⚠️ Известни проблеми

| Проблем | Приоритет | Бележка |
|---------|-----------|---------|
| `bench_scaling` SIGSEGV при 16/32 workers | **Висок** | Пада при многократен рестарт на сървър в цикъл. Възможна причина: race condition в `destroy()` при `deallocShared` под ORC с активни worker threads. |
| `HttpClient` не пази cookies автоматично | **Нисък** | Nim `HttpClient` има `handleCookies=true`, но не парсира `Set-Cookie` от отговорите на Hunos. Тестовете заобикалят това с ръчно cookie управление. |
| `std/md5` deprecated warning | **Нисък** | `staticfiles.nim` използва `std/md5`. Трябва да се смени с `checksums/md5` (изисква `nimble install checksums`). |

---

## 2. Архитектура: Как Hunos се вписва в NimMax

### 2.1 Фундаментална разлика

```
┌─────────────────────────────────────┐
│ NimMax (asynchttpserver)            │
│ • Single-threaded async/await       │
│ • Handler: Future[void] {.async.}   │
│ • Context обгръща Request+Response  │
│ • Onion middleware с switch(ctx)    │
└─────────────────────────────────────┘
           vs
┌─────────────────────────────────────┐
│ Hunos (multi-threaded)              │
│ • IO thread + worker thread pool    │
│ • Handler: void (sync) {.gcsafe.}   │
│ • Директен достъп до Request        │
│ • Pipeline middleware с next()      │
└─────────────────────────────────────┘
```

### 2.2 Три възможни пътя за интеграция

**Път A: Хибриден (препоръчителен, бърз)**
- NimMax с asynchttpserver за async страници/WebSocket
- Hunos за CPU-heavy API endpoint-и
- Proxy/Load balancer разпределя между тях
- **ROI**: 1-2 седмици, най-малко риск

**Път B: Adapter слой (среден)**
- Създава се `nimmax_hunos.nim` adapter
- Hunos обработва HTTP парсинга и routing
- Adapter пуска NimMax async handlers в отделен thread pool
- **ROI**: 1-2 месеца, компромис с performance

**Път C: Пълна миграция (труден)**
- Пренаписва се целият NimMax върху Hunos
- Всички handlers стават sync
- Чупи backward compatibility
- **ROI**: 3-6 месеца, най-висок риск

---

## 3. Пътна карта по фази

### Фаза 1: Hunos стабилизация (1-2 седмици)

**Цел**: Hunos да е production-ready като самостоятелен сървър.

| Задача | Сложност | Отговорник | Приоритет |
|--------|----------|------------|-----------|
| ✅ Fix `bench_scaling` SIGSEGV | Висока | AI | **Критичен** |
| ✅ Премахни `std/md5` deprecated warning | Ниска | AI | Нисък |
| ✅ Добави `close()` за `RateLimiter` | Ниска | AI | Нисък |
| ✅ Документация за новите модули | Средна | AI | Среден |

**Детайли за SIGSEGV fix:**
- Възпроизвежда се: `nim c --threads:on --mm:orc -d:release -r tests/bench_scaling.nim`
- Пада при 16 или 32 workers (втората половина на теста)
- Вероятна причина: `destroy()` извиква `deallocShared(server)` преди всички worker threads да са освободили GC-managed обекти от `ServerObj`
- Възможно решение: Замени `allocShared0` + `deallocShared` с ORC-safe `create`/`=destroy`, или добави `sleep(50)` преди `deallocShared`

---

### Фаза 2: Feature Parity с NimMax (2-4 седмици)

**Цел**: Hunos да има всички функции, които NimMax предоставя.

| Задача | Сложност | Бележки |
|--------|----------|---------|
| **Form Validation** | Средна | Порта на `nimmax/validation/validators.nim` — 15+ валидатора с `Option[T]` връщане |
| **Flash Messages** | Ниска | Разширение на `sessions.nim` — `ctx.flash("msg", flSuccess)` + `ctx.getFlashedMsgs()` |
| **Signed Cookie Sessions** | Средна | Алтернатива на in-memory store — криптографски подписани cookies |
| **WebSocket подобрения** | Средна | per-message compression (RFC 7692), heartbeat/ping timeout |
| **OpenAPI/Swagger** | Висока | Генериране на OpenAPI spec от router handlers — изисква reflection |
| **Testing Utilities** | Средна | `mockApp()`, `runOnce()`, `debugResponse()` — порт от `nimmax/mocking.nim` |

#### 2.1 Form Validation (примерна архитектура)

```nim
# hunos/validation.nim
import std/options, std/re, std/strutils

type
  Validator* = proc(value: string): Option[string]

proc required*(): Validator =
  return proc(value: string): Option[string] =
    if value.len == 0:
      return some("Field is required")
    return none(string)

proc isInt*(): Validator = ...
proc isEmail*(): Validator = ...
proc minLength*(n: int): Validator = ...
proc maxLength*(n: int): Validator = ...

type
  FormValidator* = object
    rules: Table[string, seq[Validator]]

proc addRule*(v: var FormValidator, field: string, validator: Validator) = ...
proc validate*(v: FormValidator, params: Table[string, string]): Table[string, seq[string]] = ...
```

#### 2.2 Flash Messages (примерна архитектура)

```nim
# Разширение на sessions.nim
type
  FlashLevel* = enum
    flInfo, flWarning, flError, flSuccess

proc flash*(session: Session, msg: string, level: FlashLevel) =
  session.set("_flash_" & $level, msg)

proc getFlashedMsgs*(session: Session): seq[(FlashLevel, string)] = ...
```

---

### Фаза 3: NimMax Integration Layer (2-4 седмици)

**Цел**: Създаване на `nimmax_hunos.nim` adapter модул.

| Задача | Сложност | Бележки |
|--------|----------|---------|
| **Async Bridge** | Висока | Thread pool за изпълнение на NimMax `Future[void]` handlers в Hunos worker thread-ове |
| **Context Mapping** | Средна | `HunosContext` → `NimMaxContext` мапер за params, cookies, sessions |
| **Middleware Bridge** | Средна | Адаптация на NimMax onion middleware към Hunos pipeline |
| **Settings Bridge** | Ниска | Мапиране на `nimmax/core/settings.nim` към Hunos server параметри |

#### 3.1 Async Bridge (ключова задача)

NimMax handlers са `proc(ctx: Context): Future[void] {.async.}`. За да работят в Hunos:

```nim
# nimmax_hunos.nim
import std/asyncdispatch, std/threadpool, hunos, nimmax

type
  AsyncBridge = ref object
    eventLoop: Thread[AsyncBridge]
    taskQueue: Channel[AsyncTask]
    resultQueue: Channel[AsyncResult]

proc runAsyncHandler*(handler: HandlerAsync, ctx: Context) {.gcsafe.} =
  # Пусни async handler в dedicated event loop thread
  # Върни резултата синхронно в Hunos worker-а
```

**Алтернатива**: Ако не искаме async bridge, можем да портираме основните NimMax middleware-и като sync Hunos middleware:
- `loggingMiddleware` → вече съществува
- `corsMiddleware` → вече съществува
- `sessionMiddleware` → вече съществува
- `csrfMiddleware` → вече съществува
- `compressionMiddleware` → вече е в `respond()`
- `staticFileMiddleware` → вече съществува
- `rateLimitMiddleware` → вече съществува
- `jsonBodyMiddleware` → лесно за добавяне

---

### Фаза 4: Performance & Production Readiness (2-4 седмици)

| Задача | Сложност | Бележки |
|--------|----------|---------|
| **HTTP/2** | Висока | Може да се добави като optional feature |
| **TLS/HTTPS** | Средна | Интеграция с `std/net` SSL или external proxy |
| **Zero-copy static files** | Средна | `sendfile()` syscall за големи файлове |
| **Connection pooling** | Средна | Keep-alive оптимизации |
| **Metrics/Prometheus** | Средна | Expose `/metrics` endpoint |
| **Structured Logging** | Ниска | JSON формат за логове |

---

## 4. Приоритетна опашка (ред на изпълнение)

```
Седмица 1-2:  SIGSEGV fix → Form Validation → Flash Messages
Седмица 3-4:  Signed Cookies → jsonBody middleware → Testing utils
Седмица 5-6:  Async Bridge → Context Mapping → Middleware Bridge
Седмица 7-8:  WebSocket compression → TLS → Metrics → Documentation
```

---

## 5. Технически бележки за другия разработчик

### 5.1 Как да компилирате и тествате

```bash
# Debug build
nim c --threads:on --mm:orc --path:src -r tests/test_<name>.nim

# Release build
nim c --threads:on --mm:orc -d:release --path:src -r tests/test_<name>.nim

# Всички тестове
for f in tests/test_*.nim; do
  echo "Testing $f..."
  nim c --threads:on --mm:orc --path:src -r "$f" || exit 1
done
```

### 5.2 Структура на нов модул

Всяка нова функция трябва да следва този шаблон:

```
src/hunos/<module>.nim       # Основен модул
tests/test_<module>.nim      # Unit тестове
docs/<module>.md             # Документация (по избор)
```

### 5.3 Coding conventions

- Всички public proc-ове имат `*` suffix
- Thread-unsafe код маркирай с коментар `## NOT thread-safe`
- Handler proc-ове винаги с `{.gcsafe.}`
- Global mutable state винаги с `Lock` или `Atomic`
- Пазете **zero dependencies** философията — използвайте stdlib когато е възможно

### 5.4 Важно: ORC + Threads

Hunos използва `--mm:orc` с `--threads:on`. Това има последици:
- `allocShared0` / `deallocShared` са **не-GC-safe**. Ако заделяте GC-managed обекти в shared памет, ORC може да ги събере преждевременно.
- `createThread` изисква `{.nimcall.}` или `{.thread.}` proc-ове, **не closure-и**.
- `seq` и `string` не могат да се споделят между thread-ове без `deepCopy` или `allocShared`.
- Глобални `var` от GC типове (string, seq, ref) трябва да се достъпват само в `{.gcsafe.}` блокове.

---

## 6. Ресурси

- **Текущ проект**: `/home/ziko/z-git/hunos/`
- **NimMax проект**: `/home/ziko/z-git/nimmax/`
- **Препоръки (детайлни)**: `hunos/RECOMMENDATIONS_NIMMAX_INTEGRATION.md`
- **Code Review**: `hunos/CODE_REVIEW.md`

---

## 7. Контакти / Въпроси

Ако сте нов разработчик по този проект:
1. Прочетете `CODE_REVIEW.md` за познати бъгове
2. Пуснете всички тестове преди да правите промени
3. Ако променяте `src/hunos.nim`, тествайте и WebSocket функционалността
4. SIGSEGV при `bench_scaling` е **known issue** — не се плашете, тествайте с `test_concurrent` вместо това
