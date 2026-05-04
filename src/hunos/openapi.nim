## openapi.nim
##
## OpenAPI 3.0 spec generator for Hunos.
##
## Usage:
##   import hunos/openapi
##
##   var spec = newOpenApiSpec("My API", "A sample API", "1.0.0")
##   spec.addServer("http://localhost:8080")
##
##   spec.addPath("/users", "get", "List users", tags = @["users"])
##   spec.addPath("/users", "post", "Create user", tags = @["users"])
##
##   let json = spec.toJson()

import std/json, std/tables, std/strutils

type
  OpenApiInfo* = object
    title*: string
    description*: string
    version*: string

  OpenApiParameter* = ref object
    name*: string
    `in`*: string
    description*: string
    required*: bool
    schema*: JsonNode

  OpenApiRequestBody* = ref object
    description*: string
    required*: bool
    content*: TableRef[string, JsonNode]

  OpenApiResponse* = ref object
    description*: string
    content*: TableRef[string, JsonNode]

  OpenApiPath* = ref object
    path*: string
    httpMethod*: string
    summary*: string
    description*: string
    tags*: seq[string]
    parameters*: seq[OpenApiParameter]
    requestBody*: OpenApiRequestBody
    responses*: TableRef[string, OpenApiResponse]
    deprecated*: bool

  OpenApiSecurityScheme* = ref object
    schemeType*: string
    scheme*: string
    name*: string
    `in`*: string
    description*: string

  OpenApiSpec* = ref object
    info*: OpenApiInfo
    paths*: seq[OpenApiPath]
    securitySchemes*: TableRef[string, OpenApiSecurityScheme]
    servers*: seq[JsonNode]

proc newOpenApiSpec*(
  title = "Hunos API",
  description = "",
  version = "1.0.0"
): OpenApiSpec =
  OpenApiSpec(
    info: OpenApiInfo(title: title, description: description, version: version),
    paths: @[],
    securitySchemes: newTable[string, OpenApiSecurityScheme](),
    servers: @[]
  )

proc addServer*(spec: OpenApiSpec, url: string, description = "") =
  var srv = newJObject()
  srv["url"] = %url
  if description.len > 0:
    srv["description"] = %description
  spec.servers.add(srv)

proc addSecurityScheme*(spec: OpenApiSpec, name: string, scheme: OpenApiSecurityScheme) =
  spec.securitySchemes[name] = scheme

proc addPath*(
  spec: OpenApiSpec,
  path, httpMethod, summary: string,
  tags: seq[string] = @[],
  description = ""
): OpenApiPath =
  result = OpenApiPath(
    path: path,
    httpMethod: httpMethod.toLowerAscii(),
    summary: summary,
    description: description,
    tags: tags,
    parameters: @[],
    responses: newTable[string, OpenApiResponse](),
    deprecated: false
  )
  spec.paths.add(result)

proc addParameter*(
  p: OpenApiPath,
  name: string,
  paramIn: string,
  description = "",
  required = true,
  schema: JsonNode = nil
) =
  let s = if schema != nil: schema else: %*{"type": "string"}
  p.parameters.add(OpenApiParameter(
    name: name, `in`: paramIn, description: description,
    required: required, schema: s
  ))

proc addRequestBody*(
  p: OpenApiPath,
  description = "",
  required = true,
  content: TableRef[string, JsonNode] = nil
) =
  p.requestBody = OpenApiRequestBody(
    description: description,
    required: required,
    content: if content != nil: content else: newTable[string, JsonNode]()
  )

proc addResponse*(
  p: OpenApiPath,
  code: string,
  description: string,
  content: TableRef[string, JsonNode] = nil
) =
  p.responses[code] = OpenApiResponse(
    description: description,
    content: if content != nil: content else: newTable[string, JsonNode]()
  )

proc toJson*(spec: OpenApiSpec): JsonNode =
  var paths = newJObject()
  for p in spec.paths:
    if not paths.hasKey(p.path):
      paths[p.path] = newJObject()

    var operation = newJObject()

    if p.summary.len > 0:
      operation["summary"] = %p.summary
    if p.description.len > 0:
      operation["description"] = %p.description
    if p.deprecated:
      operation["deprecated"] = %true
    if p.tags.len > 0:
      var tagsArr = newJArray()
      for t in p.tags:
        tagsArr.add(%t)
      operation["tags"] = tagsArr

    if p.parameters.len > 0:
      var paramsArr = newJArray()
      for param in p.parameters:
        var pObj = newJObject()
        pObj["name"] = %param.name
        pObj["in"] = %param.`in`
        if param.description.len > 0:
          pObj["description"] = %param.description
        pObj["required"] = %param.required
        pObj["schema"] = param.schema
        paramsArr.add(pObj)
      operation["parameters"] = paramsArr

    if p.requestBody != nil:
      var body = newJObject()
      if p.requestBody.description.len > 0:
        body["description"] = %p.requestBody.description
      body["required"] = %p.requestBody.required
      var bodyContent = newJObject()
      for mt, schema in p.requestBody.content:
        bodyContent[mt] = %*{"schema": schema}
      if bodyContent.len > 0:
        body["content"] = bodyContent
      else:
        body["content"] = %*{"application/json": {"schema": {"type": "object"}}}
      operation["requestBody"] = body

    var respObj = newJObject()
    if p.responses.len == 0:
      respObj["200"] = %*{"description": "Successful response"}
    else:
      for code, resp in p.responses:
        var rObj = newJObject()
        rObj["description"] = %resp.description
        if resp.content.len > 0:
          var rContent = newJObject()
          for mt, schema in resp.content:
            rContent[mt] = %*{"schema": schema}
          rObj["content"] = rContent
        respObj[code] = rObj
    operation["responses"] = respObj

    paths[p.path][p.httpMethod] = operation

  result = %*{
    "openapi": "3.0.0",
    "info": {
      "title": spec.info.title,
      "description": spec.info.description,
      "version": spec.info.version
    }
  }

  if spec.servers.len > 0:
    var serversArr = newJArray()
    for srv in spec.servers:
      serversArr.add(srv)
    result["servers"] = serversArr

  result["paths"] = paths

  if spec.securitySchemes.len > 0:
    var components = newJObject()
    var schemes = newJObject()
    for name, scheme in spec.securitySchemes:
      var sObj = newJObject()
      sObj["type"] = %scheme.schemeType
      if scheme.scheme.len > 0:
        sObj["scheme"] = %scheme.scheme
      if scheme.name.len > 0:
        sObj["name"] = %scheme.name
      if scheme.`in`.len > 0:
        sObj["in"] = %scheme.`in`
      if scheme.description.len > 0:
        sObj["description"] = %scheme.description
      schemes[name] = sObj
    components["securitySchemes"] = schemes
    result["components"] = components

proc escapeHtml*(s: string): string =
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")

proc swaggerUiHtml*(spec: OpenApiSpec, openApiPath = "/openapi.json"): string =
  """<!DOCTYPE html>
<html>
<head>
  <title>""" & escapeHtml(spec.info.title) & """ - API Documentation</title>
  <link rel="stylesheet" type="text/css" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    SwaggerUIBundle({url: '""" & openApiPath & """', dom_id: '#swagger-ui'})
  </script>
</body>
</html>"""