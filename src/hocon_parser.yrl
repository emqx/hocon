Nonterminals
  hocon
  array
  object
  fields
  field
  directive
  elements
  value
  substring
  substrings.

Terminals
  '{' '}' '[' ']' ','
  bool integer float string
  percent bytesize duration variable
  include key.

Rootsymbol hocon.
Right 100 string variable.
hocon -> object : '$1'.
hocon -> fields : '$1'.

object -> '{' fields '}' : {'$2'}.
object -> '{' '}' : {[]}.

fields -> field ',' fields : ['$1'|'$3'].
fields -> field fields : ['$1'|'$2'].
fields -> field : ['$1'].

field -> key value : {iolist_to_binary(value_of('$1')), '$2'}.
field -> directive : '$1'.

array -> '[' elements ']' : '$2'.
array -> '[' ']' : [].

elements -> value ',' elements : ['$1'|'$3'].
elements -> value elements : ['$1'|'$2'].
elements -> value : ['$1'].

directive -> include string : {'$include', value_of('$2')}.

substrings -> substring substrings : ['$1' | '$2'].
substrings -> substring : ['$1'].

substring -> string : iolist_to_binary(value_of('$1')).
substring -> variable : value_of('$1').

value -> bool : value_of('$1').
value -> integer : value_of('$1').
value -> float : value_of('$1').
value -> percent : value_of('$1').
value -> bytesize : value_of('$1').
value -> duration : value_of('$1').
value -> array : '$1'.
value -> object : '$1'.
value -> substrings : maybe_concat('$1').

Erlang code.

value_of(Token) -> element(3, Token).

maybe_concat([S]) -> S;
maybe_concat(S) -> {concat, S}.
