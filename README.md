# Hocon

LALR grammar based HOCON-like configuration Parser for Erlang/OTP.

## Spec

HOCON spec for reference: https://lightbend.github.io/config/

### Divergence from Spec and Caveats

- No unicode support (at least not verified).
- The forbidden character `@` is allowed in unquoted strings.
- Value concatenation is not allowed in keys e.g. `a b c : 42` is invalid.
- String value concatenation may span multiple lines. e.g. all below Erlang strings
  are parsed to the same result (`${key => <<"value1value2">>}`):
  * `"key=value1 value2"`
  * `"key=value1value2"`
  * `"key=\"value1\" \"value2\""`
  * `"key=value1\nvalue2"`
- `url()/file()/classpath()` includes are not supported

## Test Data

Files in sample-configs are collected from https://github.com/lightbend/config/tree/v1.4.1

## TODO

- Get values from environment variables
- Introduction doc
- Upload to hex.pm

## Reference

- https://en.wikipedia.org/wiki/Lexical_analysis#Evaluator
- https://www.crockford.com/mckeeman.html
- https://en.wikipedia.org/wiki/Backus–Naur_form

## License

Apache License 2.0, see [LICENSE](./LICENSE).

## Authors

EMQ X team

