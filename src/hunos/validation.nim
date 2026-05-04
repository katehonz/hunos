## validation.nim
##
## Form validation utilities for Hunos.
## Provides composable validators for form fields.
##
## Usage:
##   import hunos/validation
##
##   var validator = newFormValidator()
##   validator.addRule("email", required(), isEmail())
##   validator.addRule("age", required(), isInt(), minValue(18))
##
##   let errors = validator.validate(params)
##   if errors.len > 0:
##     # handle validation errors

import std/options, std/re, std/strutils, std/tables

type
  Validator* = proc(value: string): Option[string]

  FormValidator* = object
    rules*: Table[string, seq[Validator]]

proc newFormValidator*(): FormValidator =
  result.rules = initTable[string, seq[Validator]]()

proc addRule*(v: var FormValidator, field: string, validators: varargs[Validator]) =
  if field notin v.rules:
    v.rules[field] = @[]
  for validator in validators:
    v.rules[field].add(validator)

proc validate*(v: FormValidator, params: Table[string, string]): Table[string, seq[string]] =
  result = initTable[string, seq[string]]()
  for field, validators in v.rules:
    let value = if field in params: params[field] else: ""
    for validator in validators:
      let err = validator(value)
      if err.isSome():
        if field notin result:
          result[field] = @[]
        result[field].add(err.get())

proc required*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return some("Field is required")
    return none(string)

proc isInt*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    try:
      discard parseInt(value)
      return none(string)
    except ValueError:
      return some("Must be an integer")

proc isFloat*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    try:
      discard parseFloat(value)
      return none(string)
    except ValueError:
      return some("Must be a number")

proc isEmail*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    let emailPattern = re"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    if value.match(emailPattern):
      return none(string)
    return some("Must be a valid email")

proc minLength*(n: int): Validator =
  return proc(value: string): Option[string] =
    if value.len < n:
      return some("Must be at least " & $n & " characters")
    return none(string)

proc maxLength*(n: int): Validator =
  return proc(value: string): Option[string] =
    if value.len > n:
      return some("Must be at most " & $n & " characters")
    return none(string)

proc matchPattern*(pattern: string): Validator =
  let regex = re(pattern)
  return proc(value: string): Option[string] =
    if value.match(regex):
      return none(string)
    return some("Invalid format")

proc oneOf*(list: openArray[string]): Validator =
  let listSeq = @list
  return proc(value: string): Option[string] =
    if value in listSeq:
      return none(string)
    return some("Must be one of: " & listSeq.join(", "))

proc notEmpty*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return some("Cannot be empty")
    return none(string)

proc isAlpha*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    for c in value:
      if not ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')):
        return some("Must contain only letters")
    return none(string)

proc isAlphanumeric*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    for c in value:
      if not (((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))):
        return some("Must contain only letters and numbers")
    return none(string)

proc isHex*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    let hexChars = {'0'..'9', 'a'..'f', 'A'..'F'}
    for c in value:
      if c notin hexChars:
        return some("Must be a valid hex string")
    return none(string)

proc isUUID*(): Validator =
  let uuidPattern = re"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
  return proc(value: string): Option[string] =
    if value.match(uuidPattern):
      return none(string)
    return some("Must be a valid UUID")

proc isDate*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    let datePattern = re"^\d{4}-\d{2}-\d{2}$"
    if value.match(datePattern):
      return none(string)
    return some("Must be a valid date (YYYY-MM-DD)")

proc isIP*(): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    let parts = value.split('.')
    if parts.len != 4:
      return some("Must be a valid IP address")
    for part in parts:
      try:
        let num = parseInt(part)
        if num < 0 or num > 255:
          return some("Must be a valid IP address")
      except ValueError:
        return some("Must be a valid IP address")
    return none(string)

proc minValue*(n: int): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    try:
      let num = parseInt(value)
      if num < n:
        return some("Must be at least " & $n)
    except ValueError:
      return some("Must be a valid integer")
    return none(string)

proc maxValue*(n: int): Validator =
  return proc(value: string): Option[string] =
    if value.strip().len == 0:
      return none(string)
    try:
      let num = parseInt(value)
      if num > n:
        return some("Must be at most " & $n)
    except ValueError:
      return some("Must be a valid integer")
    return none(string)