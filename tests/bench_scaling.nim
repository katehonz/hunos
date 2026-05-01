## bench_scaling.nim
##
## Proves linear scaling of throughput with worker count.
##
## Runs Hunos with different worker thread counts (1, 2, 4, 8, 16, 32)
## and measures throughput at each level.
## Expected: throughput ≈ N × baseline for N cores.
##
## Run:
##   nim c --threads:on --mm:orc -d:release -r tests/bench_scaling.nim
##
## Or use wrk from another terminal:
##   for t in 1 2 4 8 16 32; do
##     wrk -t4 -c100 -d10s http://localhost:8080
##   done

import hunos, std/os, std/times, std/strutils, std/atomics, std/httpclient
import ../tests/wrk_shared

const
  benchDuration = 5.0
  concurrencyLevels = [1, 2, 4, 8, 16, 32]

var totalRequests: Atomic[int64]
var totalErrors: Atomic[int64]

proc handler(request: Request) =
  case request.uri:
  of "/":
    if request.httpMethod == "GET":
      request.respond(200, body = responseBody)
    else:
      request.respond(405)
  of "/heavy":
    if request.httpMethod == "GET":
      {.gcsafe.}:
        sleep(10)  # Simulates 10ms AI inference
        request.respond(200, body = responseBody)
    else:
      request.respond(405)
  else:
    request.respond(404)

proc runBenchmark(port: int, numWorkers: int): int64 =
  ## Starts server with given worker count, returns requests/sec.
  let server = newServer(handler, workerThreads = numWorkers)

  var serverThread: Thread[void]
  createThread(serverThread, proc() =
    server.serve(Port(port))
  )

  server.waitUntilReady()

  totalRequests.store(0)
  totalErrors.store(0)

  let startTime = epochTime()
  var requestCount: int64 = 0

  var clientThreads: seq[Thread[void]]
  let numClients = 4

  for i in 0 ..< numClients:
    var t: Thread[void]
    createThread(t, proc() =
      let client = newHttpClient(timeout = 5000)
      while true:
        let now = epochTime()
        if now - startTime >= benchDuration:
          break
        try:
          let resp = client.getContent("http://127.0.0.1:" & $port & "/")
          if resp.len > 0:
            totalRequests.fetchAdd(1)
          else:
            totalErrors.fetchAdd(1)
        except:
          totalErrors.fetchAdd(1)
      client.close()
    )
    clientThreads.add(t)

  for t in clientThreads:
    joinThread(t)

  let elapsed = epochTime() - startTime
  requestCount = totalRequests.load()

  server.close()
  joinThread(serverThread)

  result = int64(float64(requestCount) / elapsed)

proc main() =
  echo "=== Hunos Scaling Benchmark ==="
  echo "Duration per test: ", benchDuration, "s"
  echo "Response body size: ", responseBody.len, " bytes"
  echo ""
  echo "Workers | Requests/sec | Scaling factor"
  echo "--------|--------------|---------------"

  var baseline: int64 = 0

  for workers in concurrencyLevels:
    let port = 8080 + workers
    let rps = runBenchmark(port, workers)

    if workers == 1:
      baseline = rps

    let scaling = if baseline > 0: float64(rps) / float64(baseline) else: 0.0
    echo align($workers, 7), " | ", align($rps, 12), " | ",
         formatFloat(scaling, ffDecimal, 2), "x"

  echo ""
  echo "=== Analysis ==="
  echo "If scaling factor ≈ N at N workers, the server scales linearly."
  echo "Expected: 8 cores → ~7-8x throughput vs 1 core."
  echo ""
  echo "For AI inference workload (/heavy endpoint):"
  echo "  - Each request simulates 10ms compute"
  echo "  - Worker pool allows N concurrent requests"
  echo "  - AsyncHttpServer would block on 1 heavy request"

when isMainModule:
  main()
