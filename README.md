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
- Quotes next to triple-quotes needs to be escaped, otherwise they are discarded.
  Meaning `"""a""""` is parsed as `a` but not `a"`, to crrectly express `a"`, it must be one of below:
    * Escape the last `"`: `"""a\""""`;
    * Or add `~` around the string value: `"""~a"~"""` (see below).
- Multiline strings allow indentation (spaces, not tabs).
  If `~\n` (or `~\r\n`) are the only characters following the opening triple-quote, then it's a multiline string with indentation:
    * The first line `~\n` is ignored;
    * The indentation spaces of the following lines are trimed;
    * Indentation is allowed but not required for empty lines;
    * Indentation level is determined by the least number of leading spaces among the non-empty lines;
    * Backslashes are treated as escape characters, i.e. should be escaped with another backslash;
    * There is no need to escape quotes in multiline strings, but it's allowed;
    * The closing triple-quote can be either `"""` or `~"""` (`~` allows the string to end with `"` without escaping).

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
