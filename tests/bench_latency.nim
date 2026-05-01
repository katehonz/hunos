## bench_latency.nim
##
## Measures latency (P50, P95, P99) for Hunos.
## Simulates AI inference workload with 10ms compute per request.
##
## Run:
##   nim c --threads:on --mm:orc -d:release -r tests/bench_latency.nim
##
## Expected:
##   P50 ≈ 10ms (compute time only)
##   P95 ≈ 12-15ms (compute + scheduling overhead)
##   P99 ≈ 20-30ms (compute + occasional contention)

import hunos, std/os, std/times, std/strutils, std/algorithm, std/httpclient
import ./wrk_shared

const
  numRequests = 1000
  computeMs = 10

proc handler(request: Request) =
  case request.uri:
  of "/":
    if request.httpMethod == "GET":
      {.gcsafe.}:
        sleep(computeMs)
        var headers: HttpHeaders
        headers["Content-Type"] = "text/plain"
        headers["X-Server"] = "Hunos"
        request.respond(200, headers, responseBody)
    else:
      request.respond(405)
  else:
    request.respond(404)

proc main() =
  echo "=== Hunos Latency Benchmark ==="
  echo "Requests: ", numRequests
  echo "Simulated compute: ", computeMs, "ms per request"
  echo ""

  let server = newServer(handler, workerThreads = 8)

  var serverThread: Thread[void]
  createThread(serverThread, proc() =
    server.serve(Port(8081))
  )

  server.waitUntilReady()

  var latencies: seq[float64]
  latencies.setLen(numRequests)

  let client = newHttpClient(timeout = 10000)

  # Warmup
  for i in 0 ..< 10:
    try:
      discard client.getContent("http://127.0.0.1:8081/")
    except Exception:
      discard

  # Measurement
  for i in 0 ..< numRequests:
    let start = epochTime()
    try:
      let resp = client.getContent("http://127.0.0.1:8081/")
      let elapsed = (epochTime() - start) * 1000.0  # milliseconds
      latencies[i] = elapsed
      if resp.len == 0:
        echo "Warning: empty response at request ", i
    except Exception as e:
      latencies[i] = 9999.0  # mark error
      echo "Error at request ", i, ": ", e.msg

  client.close()
  server.close()
  joinThread(serverThread)

  # Sort and compute percentiles
  latencies.sort()

  proc percentile(p: float64): float64 =
    let idx = int(float64(latencies.len) * p / 100.0)
    return latencies[min(idx, latencies.len - 1)]

  let
    p50 = percentile(50)
    p75 = percentile(75)
    p90 = percentile(90)
    p95 = percentile(95)
    p99 = percentile(99)
    p999 = percentile(99.9)
    minLat = latencies[0]
    maxLat = latencies[^1]

  # Average
  var sum = 0.0
  for l in latencies:
    if l < 9999.0:
      sum += l
  let avg = sum / float64(numRequests)

  echo ""
  echo "=== Latency Results (ms) ==="
  echo "Min:    ", formatFloat(minLat, ffDecimal, 2)
  echo "Avg:    ", formatFloat(avg, ffDecimal, 2)
  echo "P50:    ", formatFloat(p50, ffDecimal, 2)
  echo "P75:    ", formatFloat(p75, ffDecimal, 2)
  echo "P90:    ", formatFloat(p90, ffDecimal, 2)
  echo "P95:    ", formatFloat(p95, ffDecimal, 2)
  echo "P99:    ", formatFloat(p99, ffDecimal, 2)
  echo "P99.9:  ", formatFloat(p999, ffDecimal, 2)
  echo "Max:    ", formatFloat(maxLat, ffDecimal, 2)
  echo ""

  echo "=== Analysis ==="
  echo "Baseline compute time: ", computeMs, "ms"
  echo "P50 overhead: ", formatFloat(p50 - float64(computeMs), ffDecimal, 2), "ms"
  echo "P99 overhead: ", formatFloat(p99 - float64(computeMs), ffDecimal, 2), "ms"
  echo ""
  if p50 < float64(computeMs + 5):
    echo "[OK] P50 latency is excellent (< compute + 5ms)"
  else:
    echo "[WARN] P50 latency is higher than expected"
  if p99 < float64(computeMs + 20):
    echo "[OK] P99 latency is acceptable (< compute + 20ms)"
  else:
    echo "[WARN] P99 latency shows contention at high concurrency"

when isMainModule:
  main()
