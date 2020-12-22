# Hocon

LALR grammar based HOCON configuration Parser for Erlang/OTP

## Spec

See: https://lightbend.github.io/config/

## Divergence from Spec and Caveats

- No unicode support (at least not verified).
- The forbidden character `@` is allowed in unquoted strings.
- Whitespaces in unquoted strings are discarded.
- whitespaces in Keys are not allowed. e.g. `a b c : 42` is invalid.

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

