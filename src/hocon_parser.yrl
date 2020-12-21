Nonterminals
  HOCON
  Array
  Object
  Members
  Member
  Elements
  Element
  Directive
  Value
  Substrings.

Terminals
  '{' '}' '[' ']' ','
  bool integer float string
  percent bytesize duration variable
  include key.

Rootsymbol HOCON.
Right 100 string variable.
HOCON -> Object: '$1'.
HOCON -> Members : '$1'.

Object -> '{' Members '}' : {'$2'}.
Object -> '{' '}' : {[]}.

Members -> Member ',' Members : ['$1'|'$3'].
Members -> Member Members : ['$1'|'$2'].
Members -> Member : ['$1'].

Member -> key Element : {iolist_to_binary(value_of('$1')), '$2'}.
Member -> Directive : '$1'.

Array -> '[' Elements ']' : '$2'.
Array -> '[' ']' : [].

Elements -> Element ',' Elements : ['$1'|'$3'].
Elements -> Element Elements : ['$1'|'$2'].
Elements -> Element : ['$1'].

Element -> Value : '$1'.
Element -> Substrings : '$1'.

Directive -> include string : {'$include', value_of('$2')}.

%% create {substr, Value} tuple to distinguish from an array of strings
Substrings -> string Substrings : [{substr, iolist_to_binary(value_of('$1'))} | '$2'].
Substrings -> variable Substrings : [{substr, iolist_to_binary(value_of('$1'))} | '$2'].
Substrings -> string : [{substr, iolist_to_binary(value_of('$1'))}].
Substrings -> variable : [{substr, iolist_to_binary(value_of('$1'))}].

Value -> bool : value_of('$1').
Value -> integer : value_of('$1').
Value -> float : value_of('$1').
Value -> percent : value_of('$1').
Value -> bytesize : value_of('$1').
Value -> duration : value_of('$1').
Value -> Array : '$1'.
Value -> Object : '$1'.

Erlang code.

value_of(Token) -> element(3, Token).

