import std/tables, std/times, std/locks

type
  RateLimiter* = object
    windowSize: float      # Time window in seconds
    maxRequests: int       # Max requests per window
    lock: Lock
    clients: Table[string, seq[float64]] # IP -> timestamps

proc newRateLimiter*(windowSize: float = 60.0, maxRequests: int = 100): RateLimiter =
  result.windowSize = windowSize
  result.maxRequests = maxRequests
  initLock(result.lock)
  result.clients = initTable[string, seq[float64]]()

proc isAllowed*(limiter: var RateLimiter, clientIP: string): bool =
  let now = epochTime()
  withLock limiter.lock:
    if clientIP notin limiter.clients:
      limiter.clients[clientIP] = @[]

    var timestamps = limiter.clients[clientIP]
    # Remove expired entries
    var valid: seq[float64]
    for ts in timestamps:
      if now - ts < limiter.windowSize:
        valid.add(ts)
    limiter.clients[clientIP] = valid

    if valid.len >= limiter.maxRequests:
      return false

    limiter.clients[clientIP].add(now)
    return true

proc cleanup*(limiter: var RateLimiter) =
  let now = epochTime()
  withLock limiter.lock:
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
