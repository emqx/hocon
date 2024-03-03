# Hocon

HOCON data parser for Erlang/OTP.

## Spec

HOCON spec for reference: https://lightbend.github.io/config/

### Divergence from Spec and Caveats

- The forbidden character `@` is allowed in unquoted strings.
- Value concatenation is not allowed in keys e.g. `a b c : 42` is invalid.
- Newlines do not prevent concatenation.
  - String (All below are parsed to the same result, which is `#{key => <<"value1value2">>}`)
    * `"key=value1 value2"`
    * `"key=value1value2"`
    * `"key=\"value1\" \"value2\""`
    * `"key=value1\nvalue2"`
  - Array (`#{key => [1,2,3,4]}`)
    * `key=[1, 2] [3, 4]`
    * `key=[1, 2]\n[3, 4]`
    * `key=[1,2,3,4]`
  - Object (`#{key => #{a => 1,b => 2}}`):
    * `key={a: 1} {b: 2}`
    * `key={a: 1}\n{b: 2}`
    * `key={a=1, b=2}`
- `url()/file()/classpath()` includes are not supported
- Immediate quote before triple-quote is invalid sytax.
    * `""""a""""` is invalid because there are 4 closing quotes instead of three.
    * As a workaround, `"""~"a"~""" is valid, see below for more details.
- Multiline strings allow indentation (spaces, not tabs).
  If `~\n` (or `~\r\n`) are the only characters following the opening triple-quote, then it's a multiline string with indentation:
    * The first line `~\n` is discarded.
    * The closing triple-quote can be either `"""` or `~"""` (`~` allows the string to end with `"` without escaping).
    * Indentation is allowed but not required for empty lines.
    * Indentation level is determined by the least number of leading spaces among the non-empty lines.
    * If the closing triple-quote takes the whole line, it's allowed to be indented less than other lines,
      but if it's indented more than other lines, the spaces are treated as part of the string.
    * Backslash is NOT a escape character.
    * If a string has three consecutive quotes, there are two workarounds:
        - Make use of string concatenation, and only escape the triple-quotes. e.g.
          ```
          a = """~
                  line1
              ~"""
              "line2\"\"\"\n"
              """~
                  line3
              ~"""
          ```
        - Use normal string with escape sequence.
          For example: `a = "line1\nline2\"\"\"\nline3\n"`

## Schema

HOCON schema (`hocon_schema`) is a type-safe data validation framework.
which is compatible to [basho cuttlefish](https://github.com/basho/cuttlefish)

See more information in [SCHEMA.md](SCHEMA.md)

## Test Data

Files in sample-configs are collected from https://github.com/lightbend/config/tree/v1.4.1

## TODO

- Upload to hex.pm

## Reference

- https://en.wikipedia.org/wiki/Lexical_analysis#Evaluator
- https://www.crockford.com/mckeeman.html
- https://en.wikipedia.org/wiki/Backus–Naur_form

## License

Apache License 2.0, see [LICENSE](./LICENSE).

## Authors

EMQX team
