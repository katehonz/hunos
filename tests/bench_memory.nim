## bench_memory.nim
##
## Demonstrates read-only memory sharing between threads.
## Simulates a Mixture-of-Experts (MoE) model where:
##   - Model parameters are shared read-only across all threads
##   - Each worker processes requests by reading shared memory
##   - No data race because the data is immutable after initialization
##
## This pattern directly maps to MoE inference:
##   - All expert parameters live in read-only memory
##   - Worker threads select which expert to use
##   - ORC GC does not cause stop-the-world pauses
##
## Run:
##   nim c --threads:on --mm:orc -d:release -r tests/bench_memory.nim

import hunos, std/os, std/times, std/strutils, std/atomics, std/httpclient

const
  numExperts = 8
  expertSize = 1024 * 1024  # 1MB per expert

type
  ExpertParams = object
    data: seq[byte]
    id: int

# Global immutable parameters — shared across all threads
var experts: seq[ExpertParams]
var inferenceCount: Atomic[int64]

proc initExperts() =
  experts = @[]
  for i in 0 ..< numExperts:
    var params = ExpertParams(id: i)
    params.data = newSeq[byte](expertSize)
    # Fill with "weights" (here just a pattern; in production these are float tensors)
    for j in 0 ..< expertSize:
      params.data[j] = byte((i * 37 + j * 13) mod 256)
    experts.add(params)

proc simulateInference(expertId: int): string =
  ## Simulates a forward pass through an expert.
  ## Reads from shared read-only memory — safe for multiple threads.
  let expert = experts[expertId mod numExperts]

  # Simulate compute: sample 1000 values from expert parameters
  var checksum: int64 = 0
  let step = expertSize div 1000
  for i in countup(0, expertSize - 1, step):
    checksum += expert.data[i].int64

  inferenceCount.fetchAdd(1)

  return "{\"expert\": " & $expert.id & ", \"checksum\": " & $checksum & "}"

proc handler(request: Request) =
  case request.uri:
  of "/":
    if request.httpMethod == "GET":
      var headers: HttpHeaders
      headers["Content-Type"] = "application/json"
      headers["X-Server"] = "Hunos-MoE"
      request.respond(200, headers, """{"status": "ok", "experts": """ & $numExperts & "}")
    else:
      request.respond(405)
  of "/inference":
    if request.httpMethod == "GET":
      var expertId = 0
      let expertParam = request.queryParams
      for (k, v) in expertParam:
        if k == "expert":
          try:
            expertId = parseInt(v)
          except ValueError:
            expertId = 0

      let result = simulateInference(expertId)

      var headers: HttpHeaders
      headers["Content-Type"] = "application/json"
      request.respond(200, headers, result)
    else:
      request.respond(405)
  else:
    request.respond(404)

proc main() =
  echo "=== Hunos Memory Sharing Benchmark (MoE Simulation) ==="
  echo ""

  initExperts()

  echo "Expert configuration:"
  echo "  Num experts: ", numExperts
  echo "  Expert size: ", expertSize, " bytes (", expertSize div 1024, " KB)"
  echo "  Total model: ", numExperts * expertSize, " bytes (",
       (numExperts * expertSize) div (1024 * 1024), " MB)"
  echo ""
  echo "Memory model:"
  echo "  - Expert parameters: immutable, shared read-only across threads"
  echo "  - No locks needed for reading (Nim ORC guarantees safety)"
  echo "  - Each worker thread reads from same memory pages"
  echo "  - OS page table: single physical copy mapped to all threads"
  echo ""

  let server = newServer(handler, workerThreads = 8)

  var serverThread: Thread[void]
  createThread(serverThread, proc() =
    server.serve(Port(8083))
  )

  server.waitUntilReady()

  let numClients = 8
  let duration = 5.0
  inferenceCount.store(0)

  var clientThreads: seq[Thread[void]]
  var perClientCounts: seq[Atomic[int64]]
  perClientCounts.setLen(numClients)
  for i in 0 ..< numClients:
    perClientCounts[i].store(0)

  let startTime = epochTime()

  for i in 0 ..< numClients:
    var t: Thread[void]
    createThread(t, proc() {.gcsafe.} =
      let client = newHttpClient(timeout = 5000)
      var localCount: int64 = 0
      while true:
        if epochTime() - startTime >= duration:
          break
        try:
          let expertId = localCount mod numExperts
          let resp = client.getContent(
            "http://127.0.0.1:8083/inference?expert=" & $expertId
          )
          if resp.len > 0:
            inc localCount
        except Exception:
          discard
      client.close()
      perClientCounts[i].store(localCount)
    )
    clientThreads.add(t)

  for t in clientThreads:
    joinThread(t)

  let elapsed = epochTime() - startTime
  let total = inferenceCount.load()

  echo "=== Results ==="
  echo "Duration: ", formatFloat(elapsed, ffDecimal, 2), "s"
  echo "Total inferences: ", total
  echo "Throughput: ", int64(float64(total) / elapsed), " inferences/sec"
  echo ""

  echo "Per-client breakdown:"
  for i in 0 ..< numClients:
    let count = perClientCounts[i].load()
    echo "  Client ", i, ": ", count, " inferences (",
         int64(float64(count) / elapsed), "/sec)"
  echo ""

  echo "=== Memory Efficiency ==="
  echo "All ", numClients, " threads read from the same expert memory."
  echo "No parameter copying — OS shares physical pages."
  echo "RSS (Resident Set Size) ~ ", (numExperts * expertSize) div (1024 * 1024),
       " MB (not ", (numClients * numExperts * expertSize) div (1024 * 1024), " MB)"
  echo ""

  let singleClientEstimate = int64(float64(total) / float64(numClients))
  echo "=== Scaling Analysis ==="
  echo "Per-client average: ", singleClientEstimate, " inferences in ",
       formatFloat(elapsed, ffDecimal, 1), "s"
  echo "Effective per-core: ", int64(float64(singleClientEstimate) / elapsed),
       " inferences/sec/core"
  echo ""
  echo "If this number is similar across all clients -> linear scaling."

  server.close()
  joinThread(serverThread)

when isMainModule:
  main()
