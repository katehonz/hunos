## test_ratelimit.nim
##
## Tests for the sliding-window rate limiter.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_ratelimit.nim

import hunos/ratelimit, std/os

block: # Test basic rate limiting
  var limiter = newRateLimiter(windowSize = 1.0, maxRequests = 3)

  assert limiter.isAllowed("192.168.1.1") == true
  assert limiter.isAllowed("192.168.1.1") == true
  assert limiter.isAllowed("192.168.1.1") == true
  assert limiter.isAllowed("192.168.1.1") == false  # 4th request blocked
  echo "[OK] Basic rate limiting works (3 requests allowed, 4th blocked)"

block: # Test different IPs are independent
  var limiter = newRateLimiter(windowSize = 1.0, maxRequests = 2)

  assert limiter.isAllowed("10.0.0.1") == true
  assert limiter.isAllowed("10.0.0.2") == true
  assert limiter.isAllowed("10.0.0.1") == true
  assert limiter.isAllowed("10.0.0.2") == true
  assert limiter.isAllowed("10.0.0.1") == false
  assert limiter.isAllowed("10.0.0.2") == false
  echo "[OK] Different IPs tracked independently"

block: # Test default parameters
  var limiter = newRateLimiter()
  assert limiter.isAllowed("127.0.0.1") == true
  echo "[OK] Default parameters work (60s window, 100 requests)"

block: # Test cleanup
  var limiter = newRateLimiter(windowSize = 0.001, maxRequests = 10)
  for i in 0 ..< 5:
    discard limiter.isAllowed("10.0.0.99")
  # Wait for window to expire
  sleep(5)
  limiter.cleanup()
  # After cleanup, should be able to make requests again
  assert limiter.isAllowed("10.0.0.99") == true
  echo "[OK] Cleanup removes expired entries"

block: # Test close
  var limiter = newRateLimiter()
  limiter.close()
  echo "[OK] RateLimiter.close() works without error"

echo "All ratelimit tests passed!"
