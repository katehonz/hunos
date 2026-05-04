# Пътна карта: AI-френдли задачи за Hunos

## Версия: 1.0
## Цел: Атомарни, самостоятелни задачи за паралелна работа от AI агенти

---

## Как да използвате тази пътна карта

Всяка задача е **самостоятелна** и може да се изпълни без познаване на целия проект.
- Прочетете секцията "Входна точка" за конкретните файлове
- Изпълнете "Тест за валидация" за проверка
- Маркирайте задачата като ✅ когато е готова

---

## Фаза A: Бързи победи (1-2 часа задача)

### ✅ A1. Fix deprecated `std/md5` warning (ГОТОВО)
**Файлове:** `src/hunos/staticfiles.nim`
**Проблем:** Компилацията вади warning: `use command nimble install checksums and import checksums/md5 instead; md5 is deprecated`
**Решение:**
```bash
nimble install checksums
```
Смени `import std/md5` с `import checksums/md5` в `staticfiles.nim`.
**Тест:** `nim c --path:src -r tests/test_staticfiles.nim` трябва да компилира без warnings.
**Зависимости:** Няма

---

### ✅ A2. Add `jsonBodyMiddleware` за Hunos (ГОТОВО)
**Файлове:** `src/hunos/jsonbody.nim` (нов), `tests/test_jsonbody.nim` (нов)
**Описание:** Създай middleware, който автоматично парсира JSON body и го закача на `request.userData`.
```nim
proc jsonBodyMiddleware*: MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    if request.headers["Content-Type"].startsWith("application/json"):
      try:
        let json = parseJson(request.body)
        request.userData = ... # или по-добре - глобална таблица
      except JsonParsingError:
        request.respond(400, body = "Invalid JSON")
        return
    next()
```
**Тест:** POST заявка с `{"name":"test"}` трябва да позволи на handler-а да достъпи JSON-а.
**Зависимости:** A1 (по избор)

---

### ✅ A3. Add `notFoundHandler` и `methodNotAllowedHandler` в Router (ГОТОВО)
**Файлове:** `src/hunos/router.nim`, `tests/test_router.nim`
**Описание:** Router-ът вече има `notFoundHandler` и `methodNotAllowedHandler` полета, но те не се използват в `toHandler()`. Поправи `toHandler()` да ги извиква вместо default отговори.
**Тест:** Създай router с custom `notFoundHandler`, изпрати заявка към несъществуващ път → трябва да получиш custom отговор.
**Зависимости:** Няма

---

### ✅ A4. Add `Request.getHeader(key: string): string` helper (ГОТОВО)
**Файлове:** `src/hunos.nim`, `tests/test_core.nim`
**Описание:** Добави удобен метод за достъп до headers с default стойност (като в NimMax).
```nim
proc getHeader*(request: Request, key: string, default = ""): string =
  result = request.headers[key]
  if result.len == 0:
    result = default
```
**Тест:** Провери че липсващ header връща default стойност.
**Зависимости:** Няма

---

### ✅ A5. Cleanup Bulgarian comments in benchmarks (ГОТОВО)
**Файлове:** `tests/bench_scaling.nim`, `tests/bench_latency.nim`, `tests/bench_memory.nim`
**Описание:** Замени всички коментари на български с английски (споменато в CODE_REVIEW.md).
**Тест:** Няма (purely documentation).
**Зависимости:** Няма

---

## Фаза B: Средни задачи (4-8 часа задача)

### ✅ B1. Port Form Validation от NimMax (ГОТОВО)
**Файлове:** `src/hunos/validation.nim` (нов), `tests/test_validation.nim` (нов)
**Входна точка:** Погледни `nimmax/src/nimmax/validation/validators.nim` за референца.
**Изисквания:**
- `FormValidator` обект с `addRule(field, validator)`
- Валидатори: `required()`, `isInt()`, `isFloat()`, `isEmail()`, `minLength(n)`, `maxLength(n)`, `matchPattern(re)`, `oneOf(list)`, `notEmpty()`, `isAlpha()`, `isAlphanumeric()`, `isHex()`, `isUUID()`, `isDate()`, `isIP()`
- `validateForm(params: Table[string, string]): Table[string, seq[string]]` - връща грешки по поле
- Всички валидатори връщат `Option[string]` (грешка или none)
**Тест:** Всяка валидатора трябва да има поне 2 теста (pass и fail).
**Зависимости:** Няма

---

### ✅ B2. Add Flash Messages към Sessions (ГОТОВО)
**Файлове:** `src/hunos/sessions.nim`, `tests/test_sessions.nim`
**Изисквания:**
```nim
proc flash*(session: Session, msg: string, level: FlashLevel)
proc getFlashedMsgs*(session: Session): seq[(FlashLevel, string)]
proc getFlashedMsgsWithCategory*(session: Session): seq[(string, string)]
type FlashLevel* = enum flInfo, flWarning, flError, flSuccess
```
- Flash съобщенията се пазят в сесията с префикс `_flash_`
- При `getFlashedMsgs()` се четат и ИЗТРИВАТ автоматично (read-once)
**Тест:** Запиши flash → прочети → провери че е изтрито → прочети отново → трябва да е празно.
**Зависимости:** A1 (sessions вече работят)

---

### ✅ B3. Add Testing Utilities (`mockApp`, `runOnce`) (ГОТОВО)
**Файлове:** `src/hunos/testing.nim` (нов), `tests/test_testing.nim` (нов)
**Входна точка:** Погледни `nimmax/src/nimmax/testing/mocking.nim` за референца.
**Изисквания:**
- `proc mockServer*(): Server` - създава сървър без да стартира socket
- `proc runOnce*(server: Server, method: string, path: string, body = "", headers = @[]): Response` - изпълнява handler синхронно
- `proc debugResponse*(response: Response): string` - форматира отговор за дебъг
**Тест:** `runOnce` трябва да изпълни handler и да върне Response без да пуска сървър.
**Зависимости:** Няма

---

### ✅ B4. Add `serveStaticFile` middleware (ГОТОВО)
**Файлове:** `src/hunos/staticfiles.nim`, `tests/test_staticfiles.nim`
**Изисквания:**
- `proc staticFileMiddleware*(rootDir: string, urlPrefix = ""): MiddlewareProc`
- Ако request path започва с `urlPrefix`, сервира файл от `rootDir`
- Поддържа: ETag, Range, If-None-Match, If-Modified-Since
- Защита срещу directory traversal
**Тест:** Заявка към `/static/style.css` трябва да върне файла с правилен Content-Type.
**Зависимости:** A1 (md5 fix)

---

### ✅ B5. Add `basicAuthMiddleware` (ГОТОВО)
**Файлове:** `src/hunos/middleware.nim` или `src/hunos/auth.nim` (нов), `tests/test_auth.nim` (нов)
**Изисквания:**
```nim
type VerifyHandler* = proc(username, password: string): bool {.gcsafe.}

proc basicAuthMiddleware*(realm: string, verifyHandler: VerifyHandler): MiddlewareProc
```
- Проверява `Authorization: Basic ...` header
- Връща 401 с `WWW-Authenticate` header ако липсва или е невалиден
**Тест:** Заявка без auth → 401. Заявка с валиден auth → 200. Заявка с невалиден auth → 401.
**Зависимости:** Няма

---

## Фаза C: Сложни задачи (8-16 часа, но ясно дефинирани)

### ✅ C1. Fix `bench_scaling` SIGSEGV (ГОТОВО)
**Файлове:** `src/hunos.nim` (core), `tests/bench_scaling.nim`
**Проблем:** При многократен рестарт на сървър (16/32 workers), `bench_scaling` пада с SIGSEGV.
**Диагностика:**
```bash
nim c --threads:on --mm:orc -d:release --path:src -r tests/bench_scaling.nim
# Пада при ~16 workers
```
**Хипотези:**
1. `deallocShared(server)` се извиква преди worker threads да освободят референции към `ServerObj`
2. ORC събира `DataEntry` обекти, които все още се използват от selector-а
3. Race condition в `destroy()` при `joinThreads`
**Възможни решения:**
- Замени `allocShared0`/`deallocShared` с ORC-safe `create`/`=destroy`
- Добави `sleep(100)` преди `deallocShared` (workaround)
- Провери дали `selector.close()` е извикан преди `deallocShared`
**Тест:** `bench_scaling` трябва да завърши без SIGSEGV за всички worker нива.
**Зависимости:** Няма (core bug)

---

### ✅ C2. Add OpenAPI Spec Generator (ГОТОВО)
**Файлове:** `src/hunos/openapi.nim` (нов), `tests/test_openapi.nim` (нов)
**Входна точка:** Погледни `nimmax/src/nimmax/openapi/openapi.nim` за референца.
**Изисквания:**
- `newOpenApiSpec*(title, description, version)`
- `addPath*(spec, path, method, summary, tags)`
- `addParameter*(path, name, paramIn, required, schema)`
- `addResponse*(path, statusCode, description, contentType, schema)`
- `toJson*(spec): JsonNode` - генерира OpenAPI 3.0 JSON
- `serveDocs*(spec, path = "/docs")` - middleware, който сервира Swagger UI
**Тест:** Спецификацията трябва да е валиден OpenAPI 3.0 JSON.
**Зависимости:** B3 (testing utils помагат за тестове)

---

### ✅ C3. Add Signed Cookie Session Backend (ГОТОВО)
**Файлове:** `src/hunos/sessions.nim`, `tests/test_sessions.nim`
**Изисквания:**
- Нов `SessionBackend` enum стойност: `sbSignedCookie`
- Криптографско подписване на session cookie с HMAC-SHA256
- Проверка на подписа при четене (invalid → нова сесия)
- Автоматично expiration чрез timestamp в cookie
```nim
proc sessionMiddleware*(
  backend = sbMemory,
  secretKey = SecretKey(""),
  ...
): MiddlewareProc
```
**Входна точка:** Погледни `nimmax/src/nimmax/middlewares/sessions/memorysession.nim` за `signedCookieSessionMiddleware`.
**Тест:** Модифицирай сесия → рестарт на сървър → сесията трябва да е валидна ако подписът е правилен. Промени cookie → трябва да се създаде нова сесия.
**Зависимости:** B2 (flash messages по избор)

---

### ✅ C4. Add HTTP/2 Support (Experimental) (ГОТОВО)
**Файлове:** `src/hunos.nim` (core)
**Изисквания:**
- ALPN negotiation при TLS handshake
- HTTP/2 frame parser (HEADERS, DATA, SETTINGS, PING, GOAWAY)
- HPACK header compression
- Stream multiplexing
**Бележка:** Това е огромна задача. Алтернатива: добави `h2c` (HTTP/2 over cleartext) support първо.
**Тест:** Client с HTTP/2 трябва да може да изпраща заявки.
**Зависимости:** C1 (стабилен core)

---

## Фаза D: Интеграция с NimMax (изисква познаване и на двата проекта)

### ✅ D1. Създай `nimmax_hunos.nim` adapter (ГОТОВО)
**Файлове:** `examples/nimmax_hunos.nim` (нов)
**Изисквания:**
- Hunos server, който обработва NimMax routes
- NimMax Context се мапва към Hunos Request
```nim
proc adaptHandler*(nimmaxHandler: HandlerAsync): RequestHandler =
  return proc(request: Request) {.gcsafe.} =
    # Създай NimMax Context от Hunos Request
    # Изпълни async handler в dedicated thread
    # Върни резултата
```
**Тест:** NimMax hello-world handler трябва да работи върху Hunos.
**Зависимости:** B3, C3

---

## Бърз справочник: Зависимости между задачите

```
A1 (md5 fix) ──→ B4 (static middleware)
                 │
A2 (json body) ──┼─→ B3 (testing utils) ──→ C2 (openapi)
                 │
A3 (router fix) ─┤
                 │
A4 (getHeader) ──┤
                 │
A5 (comments) ───┘

B1 (validation) ──→ D1 (adapter)
B2 (flash) ──→ C3 (signed cookies)
B5 (basic auth)

C1 (SIGSEGV) ──→ C4 (HTTP/2)
```

---

## Чеклист за AI агент

Преди да започнеш нова задача:
- [ ] Прочетох входната точка (конкретни файлове)
- [ ] Разбирам какво трябва да се промени
- [ ] Създадох тестове ПРЕДИ да пипам кода
- [ ] Пуснах всички съществуващи тестове — минават
- [ ] Направих промените
- [ ] Тестовете за новата функция минават
- [ ] Всички съществуващи тестове все още минават
- [ ] Commit с описателно съобщение

---

## Контакти / Ресурси

- **Hunos:** `/home/ziko/z-git/hunos/`
- **NimMax (референца):** `/home/ziko/z-git/nimmax/`
- **Code Review:** `hunos/CODE_REVIEW.md`
- **Препоръки:** `hunos/RECOMMENDATIONS_NIMMAX_INTEGRATION.md`
- **Пътна карта:** `hunos/ROADMAP_NIMMAX_INTEGRATION.md`
