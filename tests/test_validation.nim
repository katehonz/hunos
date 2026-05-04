## test_validation.nim
##
## Tests for form validation.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_validation.nim

import hunos/validation, std/tables, std/options

block: # Test required validator
  echo "[TEST] required validator"
  let v = required()
  assert v("").isSome()
  assert v("  ").isSome()
  assert v("hello").isNone()
  echo "[OK] required validator works"

block: # Test isInt validator
  echo "[TEST] isInt validator"
  let v = isInt()
  assert v("").isNone()
  assert v("123").isNone()
  assert v("-456").isNone()
  assert v("12.3").isSome()
  assert v("abc").isSome()
  echo "[OK] isInt validator works"

block: # Test isEmail validator
  echo "[TEST] isEmail validator"
  let v = isEmail()
  assert v("").isNone()
  assert v("test@example.com").isNone()
  assert v("user.name@domain.org").isNone()
  assert v("invalid").isSome()
  assert v("@nodomain").isSome()
  assert v("noat.com").isSome()
  echo "[OK] isEmail validator works"

block: # Test minLength validator
  echo "[TEST] minLength validator"
  let v = minLength(5)
  assert v("").isSome()
  assert v("abc").isSome()
  assert v("abcdef").isNone()
  assert v("12345").isNone()
  echo "[OK] minLength validator works"

block: # Test maxLength validator
  echo "[TEST] maxLength validator"
  let v = maxLength(3)
  assert v("").isNone()
  assert v("ab").isNone()
  assert v("abc").isNone()
  assert v("abcd").isSome()
  echo "[OK] maxLength validator works"

block: # Test oneOf validator
  echo "[TEST] oneOf validator"
  let v = oneOf(["red", "green", "blue"])
  assert v("red").isNone()
  assert v("green").isNone()
  assert v("blue").isNone()
  assert v("yellow").isSome()
  assert v("").isSome()
  echo "[OK] oneOf validator works"

block: # Test isAlphanumeric validator
  echo "[TEST] isAlphanumeric validator"
  let v = isAlphanumeric()
  assert v("abc123").isNone()
  assert v("hello").isNone()
  assert v("").isNone()
  assert v("hello world").isSome()
  assert v("hello!").isSome()
  echo "[OK] isAlphanumeric validator works"

block: # Test isUUID validator
  echo "[TEST] isUUID validator"
  let v = isUUID()
  assert v("550e8400-e29b-41d4-a716-446655440000").isNone()
  assert v("invalid-uuid").isSome()
  assert v("550e8400e29b41d4a716446655440000").isSome()
  echo "[OK] isUUID validator works"

block: # Test FormValidator with multiple rules
  echo "[TEST] FormValidator with multiple rules"
  var validator = newFormValidator()
  validator.addRule("name", required(), minLength(2))
  validator.addRule("age", required(), isInt(), minValue(18))
  validator.addRule("email", required(), isEmail())

  var params = initTable[string, string]()
  params["name"] = "John"
  params["age"] = "25"
  params["email"] = "john@example.com"

  let errors = validator.validate(params)
  assert errors.len == 0, "Valid input should have no errors"
  echo "[OK] FormValidator validates correctly"

block: # Test FormValidator catches errors
  echo "[TEST] FormValidator catches errors"
  var validator = newFormValidator()
  validator.addRule("email", required(), isEmail())
  validator.addRule("age", isInt(), minValue(18))

  var params = initTable[string, string]()
  params["email"] = "not-an-email"
  params["age"] = "15"

  let errors = validator.validate(params)
  assert "email" in errors, "Should have email error"
  assert "age" in errors, "Should have age error"
  assert errors["email"].len == 1
  assert errors["age"].len == 1
  echo "[OK] FormValidator catches errors correctly"

block: # Test minValue and maxValue validators
  echo "[TEST] minValue/maxValue validators"
  let minV = minValue(10)
  let maxV = maxValue(100)
  assert minV("5").isSome()
  assert minV("10").isNone()
  assert minV("50").isNone()
  assert maxV("50").isNone()
  assert maxV("150").isSome()
  echo "[OK] minValue/maxValue validators work"

echo ""
echo "All validation tests passed!"