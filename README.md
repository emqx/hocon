# Hocon

LALR grammar based HOCON-like configuration Parser for Erlang/OTP.

## Spec

HOCON spec for reference: https://lightbend.github.io/config/

NOTE: Our goal is not to make this library fully compliant to HOCON spec.

### Divergence from Spec and Caveats

- No unicode support (at least not verified).
- The forbidden character `@` is allowed in unquoted strings.
- Value concatenation is not allowed in keys e.g. `a b c : 42` is invalid.
- Value concatenation is only allowed for string values,
  and the concatenation may span multiple lines. e.g. all below Erlang strings
  are parsed to the same result (`${key => <<"value1value2">>}`):
  * `"key=value1 value2"`
  * `"key=value1value2"`
  * `"key=\"value1\" \"value2\""`
  * `"key=value1\nvalue2"`

## Test Data

Files in sample-configs are collected from https://github.com/lightbend/config/tree/v1.4.1

## TODO

- Substitutions
- Object merging
- Include semantics: merging
- Get values from environment variables
- Introduction doc
- Upload to hex.pm
- Grammer file in BNF syntax
- Grammer file in McKeeman Form

## Reference

- https://en.wikipedia.org/wiki/Lexical_analysis#Evaluator
- https://www.crockford.com/mckeeman.html
- https://en.wikipedia.org/wiki/Backus–Naur_form

## License

Apache License 2.0, see [LICENSE](./LICENSE).

## Authors

EMQ X team

