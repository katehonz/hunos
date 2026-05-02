import std/atomics, std/tables, std/times, std/locks

type
  RateLimiter* = object
    windowSize: float
    maxRequests: int
    cleanupCount: Atomic[int]
    lock: Lock
    clients: Table[string, seq[float64]]

proc newRateLimiter*(windowSize: float = 60.0, maxRequests: int = 100): RateLimiter =
  result.windowSize = windowSize
  result.maxRequests = maxRequests
  result.cleanupCount.store(0)
  initLock(result.lock)
  result.clients = initTable[string, seq[float64]]()

proc close*(limiter: var RateLimiter) =
  deinitLock(limiter.lock)

proc cleanupLocked(limiter: var RateLimiter, now: float64) =
  var toDelete: seq[string]
  for ip, timestamps in limiter.clients:
    var hasValid = false
    for ts in timestamps:
      if now - ts < limiter.windowSize:
        hasValid = true
        break
    if not hasValid:
      toDelete.add(ip)
  for ip in toDelete:
    limiter.clients.del(ip)

proc isAllowed*(limiter: var RateLimiter, clientIP: string): bool =
  let now = epochTime()
  let count = limiter.cleanupCount.fetchAdd(1) + 1

  withLock limiter.lock:
    if count mod 10000 == 0:
      cleanupLocked(limiter, now)

    if clientIP notin limiter.clients:
      limiter.clients[clientIP] = @[]

    var writeIdx = 0
    for readIdx in 0 ..< limiter.clients[clientIP].len:
      if now - limiter.clients[clientIP][readIdx] < limiter.windowSize:
        limiter.clients[clientIP][writeIdx] = limiter.clients[clientIP][readIdx]
        inc writeIdx
    limiter.clients[clientIP].setLen(writeIdx)

    if writeIdx >= limiter.maxRequests:
      return false

    limiter.clients[clientIP].add(now)
    return true

proc cleanup*(limiter: var RateLimiter) =
  let now = epochTime()
  withLock limiter.lock:
    cleanupLocked(limiter, now)
