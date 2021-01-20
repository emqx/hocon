Nonterminals
  hocon
  fields
  field
  directive
  elements
  value
  partial
  partials.

Terminals
  '{' '}' '[' ']' ','
  bool integer float null
  percent bytesize duration
  string variable unquoted
  endstr endvar endarr endobj endunq
  include key required.

Rootsymbol hocon.
hocon -> '{' fields endobj : '$2'.
hocon -> fields : '$1'.

partials -> partial partials : ['$1' | '$2'].
partials -> endstr : [iolist_to_binary(value_of('$1'))].
partials -> endunq : [iolist_to_binary(value_of('$1'))].
partials -> endvar : [value_of('$1')].
partials -> '{' fields endobj : [{'$2'}].
partials -> '[' elements endarr : ['$2'].
partials -> '{' endobj : [{}].
partials -> '[' endarr : [].

partial -> string : iolist_to_binary(value_of('$1')).
partial -> unquoted : iolist_to_binary(value_of('$1')).
partial -> variable : value_of('$1').
partial -> '{' fields '}' : {'$2'}.
partial -> '{' '}' : {[{}]}.
partial -> '[' elements ']' : '$2'.
partial -> '[' ']' : [].

fields -> field ',' fields : ['$1'|'$3'].
fields -> field fields : ['$1'|'$2'].
fields -> field : ['$1'].

field -> key value : {value_of('$1'), '$2'}.
field -> directive : '$1'.

elements -> value ',' elements : ['$1'|'$3'].
elements -> value elements : ['$1'|'$2'].
elements -> value : ['$1'].

directive -> include string : {'$include', #{filename => value_of('$2'), required => false}}.
directive -> include endstr : {'$include', #{filename => value_of('$2'), required => false}}.
directive -> include required string : {'$include', #{filename => value_of('$3'), required => true}}.
directive -> include required endstr : {'$include', #{filename => value_of('$3'), required => true}}.

value -> null : null.
value -> bool : value_of('$1').
value -> integer : value_of('$1').
value -> float : value_of('$1').
value -> percent : value_of('$1').
value -> bytesize : value_of('$1').
value -> duration : value_of('$1').
value -> partials : maybe_concat('$1').

Erlang code.

value_of(Token) -> element(3, Token).

maybe_concat([]) -> [];
maybe_concat([S]) when is_binary(S) -> S;
maybe_concat(S) -> {concat, S}.
