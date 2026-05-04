## test_openapi.nim
##
## Tests for OpenAPI spec generator.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_openapi.nim

import hunos/openapi, std/json, std/tables, std/strutils

block: # Test newOpenApiSpec
  echo "[TEST] newOpenApiSpec"
  let spec = newOpenApiSpec("Test API", "A test API", "1.0.0")
  assert spec.info.title == "Test API"
  assert spec.info.description == "A test API"
  assert spec.info.version == "1.0.0"
  assert spec.paths.len == 0
  echo "[OK] newOpenApiSpec creates valid spec"

block: # Test addServer
  echo "[TEST] addServer"
  let spec = newOpenApiSpec()
  spec.addServer("http://localhost:8080", "Local dev")
  assert spec.servers.len == 1
  echo "[OK] addServer adds server"

block: # Test addPath
  echo "[TEST] addPath"
  let spec = newOpenApiSpec()
  let p = spec.addPath("/users", "get", "List users", tags = @["users"])
  assert spec.paths.len == 1
  assert p.path == "/users"
  assert p.httpMethod == "get"
  assert p.summary == "List users"
  assert "users" in p.tags
  echo "[OK] addPath creates path entry"

block: # Test addParameter
  echo "[TEST] addParameter"
  let spec = newOpenApiSpec()
  let p = spec.addPath("/users/@id", "get", "Get user")
  p.addParameter("id", "path", description = "User ID", required = true)
  assert p.parameters.len == 1
  assert p.parameters[0].name == "id"
  assert p.parameters[0].`in` == "path"
  assert p.parameters[0].required == true
  echo "[OK] addParameter adds parameter to path"

block: # Test addResponse
  echo "[TEST] addResponse"
  let spec = newOpenApiSpec()
  let p = spec.addPath("/users", "get", "List users")
  p.addResponse("200", "Successful response")
  p.addResponse("401", "Unauthorized")
  assert p.responses.len == 2
  assert "200" in p.responses
  assert "401" in p.responses
  echo "[OK] addResponse adds response to path"

block: # Test toJson produces valid OpenAPI 3.0
  echo "[TEST] toJson produces valid OpenAPI 3.0 JSON"
  let spec = newOpenApiSpec("Pet Store", "A sample pet store", "1.0.0")
  spec.addServer("http://localhost:8080", "Local dev")

  let p1 = spec.addPath("/pets", "get", "List all pets", tags = @["pets"])
  p1.addParameter("limit", "query", description = "Max items", required = false,
                  schema = %*{"type": "integer", "format": "int32"})
  p1.addResponse("200", "A list of pets")
  p1.addResponse("500", "Server error")

  let p2 = spec.addPath("/pets", "post", "Create a pet", tags = @["pets"])
  p2.addRequestBody(description = "Pet to add", required = true)
  p2.addResponse("201", "Pet created")

  let p3 = spec.addPath("/pets/@id", "get", "Get a pet by ID", tags = @["pets"])
  p3.addParameter("id", "path", description = "Pet ID", required = true)
  p3.addResponse("200", "A pet")
  p3.addResponse("404", "Not found")

  let json = spec.toJson()

  assert json["openapi"].str == "3.0.0"
  assert json["info"]["title"].str == "Pet Store"
  assert json["info"]["version"].str == "1.0.0"
  assert json["servers"].len == 1
  assert json["paths"].len == 2
  assert "/pets" in json["paths"]
  assert "/pets/@id" in json["paths"]
  assert "get" in json["paths"]["/pets"]
  assert "post" in json["paths"]["/pets"]
  assert json["paths"]["/pets"]["get"]["parameters"].len == 1
  assert json["paths"]["/pets"]["get"]["summary"].str == "List all pets"
  assert "200" in json["paths"]["/pets"]["get"]["responses"]
  assert "404" in json["paths"]["/pets/@id"]["get"]["responses"]

  let jsonStr = json.pretty()
  assert jsonStr.contains("Pet Store")
  assert jsonStr.contains("/pets")
  assert jsonStr.contains("200")
  echo "[OK] toJson produces valid OpenAPI 3.0 JSON"
  echo "[OK] Paths, parameters, responses are correct"

block: # Test security scheme
  echo "[TEST] Security scheme"
  let spec = newOpenApiSpec()
  let scheme = OpenApiSecurityScheme(
    schemeType: "http",
    scheme: "bearer",
    description: "JWT token"
  )
  spec.addSecurityScheme("bearerAuth", scheme)

  let json = spec.toJson()
  assert "components" in json
  assert "securitySchemes" in json["components"]
  assert "bearerAuth" in json["components"]["securitySchemes"]
  assert json["components"]["securitySchemes"]["bearerAuth"]["type"].str == "http"
  assert json["components"]["securitySchemes"]["bearerAuth"]["scheme"].str == "bearer"
  echo "[OK] Security scheme added correctly"

block: # Test swaggerUiHtml
  echo "[TEST] swaggerUiHtml"
  let spec = newOpenApiSpec("My API", "Test", "1.0.0")
  let html = spec.swaggerUiHtml("/api/openapi.json")
  assert html.contains("<title>My API - API Documentation</title>")
  assert html.contains("swagger-ui")
  assert html.contains("/api/openapi.json")
  echo "[OK] swaggerUiHtml generates valid HTML"

block: # Test path with no responses gets default 200
  echo "[TEST] Default 200 response"
  let spec = newOpenApiSpec()
  discard spec.addPath("/health", "get", "Health check")

  let json = spec.toJson()
  assert "200" in json["paths"]["/health"]["get"]["responses"]
  assert json["paths"]["/health"]["get"]["responses"]["200"]["description"].str == "Successful response"
  echo "[OK] Default 200 response added when no responses specified"

echo ""
echo "All OpenAPI tests passed!"