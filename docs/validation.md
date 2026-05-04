# Form Validation (`hunos/validation`)

NimMax-style form validation with composable validators.

## Usage

```nim
import hunos/validation

var validator = newFormValidator()
validator.addRule("email", required())
validator.addRule("email", isEmail())
validator.addRule("age", isInt())
validator.addRule("age", minValue(18))

let errors = validator.validate(params)
# errors: Table[string, seq[string]]
if errors.len > 0:
  # Handle validation errors
```

## Available Validators

| Validator | Description | Example Fail |
|-----------|-------------|--------------|
| `required()` | Non-empty string | `""` |
| `isInt()` | Parseable integer | `"abc"` |
| `isFloat()` | Parseable float | `"xyz"` |
| `isEmail()` | Email format | `"not-an-email"` |
| `minLength(n)` | Minimum length | `"ab"` with `minLength(3)` |
| `maxLength(n)` | Maximum length | `"abcd"` with `maxLength(3)` |
| `minValue(n)` | Minimum numeric value | `"5"` with `minValue(10)` |
| `maxValue(n)` | Maximum numeric value | `"20"` with `maxValue(10)` |
| `matchPattern(re)` | Regex match | `"hello"` with `re"^\\d+$"` |
| `oneOf(list)` | Value in list | `"x"` with `oneOf(@["a", "b"])` |
| `notEmpty()` | Non-empty string | `""` |
| `isAlpha()` | Alphabetic only | `"abc123"` |
| `isAlphanumeric()` | Alphanumeric only | `"abc-123"` |
| `isHex()` | Hexadecimal | `"0xGG"` |
| `isUUID()` | UUID format | `"not-a-uuid"` |
| `isDate()` | Date format | `"tomorrow"` |
| `isIP()` | IPv4 or IPv6 | `"999.999.999.999"` |

## Custom Validators

```nim
proc myValidator(): Validator =
  return proc(value: string): Option[string] =
    if value != "expected":
      return some("Value must be 'expected'")
    return none(string)

validator.addRule("field", myValidator())
```
