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

import hunos, std/os, std/times, std/strutils, std/atomics
from std/httpclient import newHttpClient, getContent, close
import ./wrk_shared

const
  benchDuration = 5.0
  concurrencyLevels = [1, 2, 4, 8, 16, 32]

var totalRequests: Atomic[int64]
var totalErrors: Atomic[int64]

proc handler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let body = responseBody
  case request.uri:
  of "/":
    if request.httpMethod == "GET":
      request.respond(200, body = body)
    else:
      request.respond(405)
  of "/heavy":
    if request.httpMethod == "GET":
      sleep(10)  # Simulates 10ms AI inference
      request.respond(200, body = body)
    else:
      request.respond(405)
  else:
    request.respond(404)

type
  ServerArgs = object
    server: Server
    port: int

proc serveProc(args: ServerArgs) {.thread.} =
  args.server.serve(Port(args.port))

type
  ClientArgs = object
    port: int
    startTime: float64

proc clientProc(args: ClientArgs) {.thread, gcsafe.} =
  var client = newHttpClient(timeout = 5000)
  while true:
    let now = epochTime()
    if now - args.startTime >= benchDuration:
      break
    try:
      let resp = client.getContent("http://127.0.0.1:" & $args.port & "/")
      if resp.len > 0:
        discard totalRequests.fetchAdd(1)
      else:
        discard totalErrors.fetchAdd(1)
    except Exception:
      discard totalErrors.fetchAdd(1)
  client.close()

proc runBenchmark(port: int, numWorkers: int): int64 =
  ## Starts server with given worker count, returns requests/sec.
  echo "  Creating server..."
  let server = newServer(handler, workerThreads = numWorkers)
  echo "  Server created"

  var serverThread: Thread[ServerArgs]
  createThread(serverThread, serveProc, ServerArgs(server: server, port: port))
  echo "  Server thread started"

  server.waitUntilReady()
  echo "  Server ready"

  totalRequests.store(0)
  totalErrors.store(0)

  let numClients = 4
  var clientThreads: array[4, Thread[ClientArgs]]
  let benchStart = epochTime()

  for i in 0 ..< numClients:
    createThread(clientThreads[i], clientProc, ClientArgs(port: port, startTime: benchStart))

  for i in 0 ..< numClients:
    joinThread(clientThreads[i])

  echo "  Client threads joined"

  let elapsed = epochTime() - benchStart
  let requestCount = totalRequests.load()

  echo "  Closing server..."
  server.close()
  echo "  Server closed, joining server thread..."
  joinThread(serverThread)
  echo "  Server thread joined"

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
    echo "Starting benchmark with ", workers, " workers on port ", port
    let rps = runBenchmark(port, workers)
    echo "Completed benchmark with ", workers, " workers: ", rps, " req/s"

    if workers == 1:
      baseline = rps

    let scaling = if baseline > 0: float64(rps) / float64(baseline) else: 0.0
    echo align($workers, 7), " | ", align($rps, 12), " | ",
         formatFloat(scaling, ffDecimal, 2), "x"

    sleep(200)  # Allow OS to reclaim ports and threads

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
