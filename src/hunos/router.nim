import ../hunos, std/tables, std/strutils

type
  Router* = object
    notFoundHandler*: RequestHandler
    methodNotAllowedHandler*: RequestHandler
    errorHandler*: proc(request: Request, e: ref Exception) {.gcsafe.}
    root: TrieNode

  TrieNode = ref object
    children: Table[string, TrieNode]
    paramChild: TrieNode
    paramName: string
    wildcardChild: TrieNode
    partialChild: TrieNode
    partialPrefix: string
    partialSuffix: string
    methods: Table[string, RequestHandler]

proc newRouter*(): Router =
  result.root = TrieNode()

proc splitPath(path: string): seq[string] =
  if path.len == 0 or path[0] != '/':
    return @[]
  var parts = path.split('/')
  parts.delete(0)
  result = parts

proc addRoute*(
  router: var Router,
  httpMethod, route: string,
  handler: RequestHandler
) =
  if route == "":
    raise newException(HunosError, "Invalid empty route")
  if route[0] != '/':
    raise newException(HunosError, "Routes must begin with /")

  let parts = splitPath(route)
  var node = router.root

  for part in parts:
    if part.len >= 2 and part[0] == '@':
      if node.paramChild == nil:
        node.paramChild = TrieNode()
        node.paramName = part[1 .. ^1]
      node = node.paramChild
    elif part == "**":
      if node.wildcardChild == nil:
        node.wildcardChild = TrieNode()
      node = node.wildcardChild
      break
    elif '*' in part:
      if node.partialChild == nil:
        node.partialChild = TrieNode()
        let starPos = part.find('*')
        node.partialPrefix = part[0 ..< starPos]
        node.partialSuffix = part[starPos + 1 .. ^1]
      node = node.partialChild
    else:
      if part notin node.children:
        node.children[part] = TrieNode()
      node = node.children[part]

  node.methods[httpMethod] = handler

proc get*(router: var Router, route: string, handler: RequestHandler) =
  router.addRoute("GET", route, handler)

proc head*(router: var Router, route: string, handler: RequestHandler) =
  router.addRoute("HEAD", route, handler)

proc post*(router: var Router, route: string, handler: RequestHandler) =
  router.addRoute("POST", route, handler)

proc put*(router: var Router, route: string, handler: RequestHandler) =
  router.addRoute("PUT", route, handler)

proc delete*(router: var Router, route: string, handler: RequestHandler) =
  router.addRoute("DELETE", route, handler)

proc options*(router: var Router, route: string, handler: RequestHandler) =
  router.addRoute("OPTIONS", route, handler)

proc patch*(router: var Router, route: string, handler: RequestHandler) =
  router.addRoute("PATCH", route, handler)

proc defaultNotFoundHandler(request: Request) =
  const body = "<h1>Not Found</h1>"
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  if request.httpMethod == "HEAD":
    headers["Content-Length"] = $body.len
    request.respond(404, headers)
  else:
    request.respond(404, headers, body)

proc defaultMethodNotAllowedHandler(request: Request) =
  const body = "<h1>Method Not Allowed</h1>"
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  if request.httpMethod == "HEAD":
    headers["Content-Length"] = $body.len
    request.respond(405, headers)
  else:
    request.respond(405, headers, body)

proc matchNode(
  node: TrieNode,
  parts: seq[string],
  pathParams: var PathParams,
  idx: int
): (TrieNode, bool) =
  if idx >= parts.len:
    return (node, true)

  let part = parts[idx]

  if part in node.children:
    let (n, ok) = matchNode(node.children[part], parts, pathParams, idx + 1)
    if ok:
      return (n, true)

  if node.partialChild != nil:
    let prefix = node.partialPrefix
    let suffix = node.partialSuffix
    if part.len >= prefix.len + suffix.len and
       (prefix.len == 0 or part.startsWith(prefix)) and
       (suffix.len == 0 or part.endsWith(suffix)):
      let (n, ok) = matchNode(node.partialChild, parts, pathParams, idx + 1)
      if ok:
        return (n, true)

  if node.paramChild != nil:
    pathParams.add((node.paramName, part))
    let (n, ok) = matchNode(node.paramChild, parts, pathParams, idx + 1)
    if ok:
      return (n, true)
    # Backtrack: remove the param we just added
    if pathParams.len > 0:
      pathParams.setLen(pathParams.len - 1)

  if node.wildcardChild != nil:
    return (node.wildcardChild, true)

  return (nil, false)

proc toHandler*(router: Router): RequestHandler =
  return proc(request: Request) =
    template notFound() =
      if router.notFoundHandler != nil:
        router.notFoundHandler(request)
      else:
        defaultNotFoundHandler(request)

    if request.path.len == 0 or request.path[0] != '/':
      notFound()
      return

    try:
      let pathParts = splitPath(request.path)

      request.pathParams.setLen(0)
      let (matchedNode, ok) = matchNode(router.root, pathParts, request.pathParams, 0)

      if ok and matchedNode != nil and request.httpMethod in matchedNode.methods:
        matchedNode.methods[request.httpMethod](request)
        return

      # Check if any method matches (for 405)
      if ok and matchedNode != nil and matchedNode.methods.len > 0:
        if router.methodNotAllowedHandler != nil:
          router.methodNotAllowedHandler(request)
        else:
          defaultMethodNotAllowedHandler(request)
        return

      notFound()
    except Exception as e:
      if router.errorHandler != nil:
        router.errorHandler(request, e)
      else:
        raise e

converter convertToHandler*(router: Router): RequestHandler =
  router.toHandler()
