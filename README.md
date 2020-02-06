# Hocon

LALR grammar based HOCON configuration Parser for Erlang/OTP

## Spec

See: https://lightbend.github.io/config/

## Grammer

The HOCON grammar in [McKeeman Form](https://www.crockford.com/mckeeman.html):

```
hocon
   element

name
    letter
    letter name
    letter '_' name
    letter '.' name

letter
    'a' . 'z'
    'A' . 'Z'

value
   object
   array
   string
   number
   "true"
   "false"
   "null"

object
    '{' ws '}'
    '{' members '}'

members
    member
    member ',' members
member
    ws string ws ':' element

array
    '[' ws ']'
    '[' elements ']'

elements
    element
    element ',' elements

element
    ws value ws

string
    '"' characters '"'

characters
    ""
    character characters

character
    '0020' . '10FFFF' - '"' - '\'
    '\' escape

escape
    '"'
    '\'
    '/'
    'b'
    'f'
    'n'
    'r'
    't'
    'u' hex hex hex hex

hex
    digit
    'A' . 'F'
    'a' . 'f'

number
    integer fraction exponent

integer
    digit
    onenine digits
    '-' digit
    '-' onenine digits

digits
    digit
    digit digits

digit
    '0'
    onenine

onenine
    '1' . '9'

fraction
    ""
    '.' digits

exponent
    ""
    'E' sign digits
    'e' sign digits

sign
    ""
    '+'
    '-'
ws
    ""
    '0020' ws
    '000A' ws
    '000D' ws
    '0009' ws

space
    '0020'

newline
    '000A'
```

## Reference

- https://en.wikipedia.org/wiki/Lexical_analysis#Evaluator
- https://www.crockford.com/mckeeman.html
- https://en.wikipedia.org/wiki/Backus–Naur_form

## License

Apache License 2.0, see [LICENSE](./LICENSE).

## Author

Feng at emqx.io <feng@emqx.io>

