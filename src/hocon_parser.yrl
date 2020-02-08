Nonterminals
  HOCON
  Array
  Object
  Members
  Member
  Elements
  Element
  Directive
  Key
  Value.

Terminals
  '{' '}' '[' ']' ',' ':' '='
  bool atom integer float string
  percent bytesize duration variable
  include.

Rootsymbol HOCON.

HOCON -> Object: '$1'.
HOCON -> Members : '$1'.

Object -> '{' Members '}' : {'$2'}.
Object -> '{' '}' : {[]}.

Members -> Member ',' Members : ['$1'|'$3'].
Members -> Member Members : ['$1'|'$2'].
Members -> Member : ['$1'].

Member -> Key Object : {'$1', '$2'}.
Member -> Key ':' Element : {'$1', '$3'}.
Member -> Key '=' Element : {'$1', '$3'}.
Member -> Directive : '$1'.

Array -> '[' Elements ']' : '$2'.
Array -> '[' ']' : [].

Elements -> Element ',' Elements : ['$1'|'$3'].
Elements -> Element Elements : ['$1'|'$2'].
Elements -> Element : ['$1'].

Element -> Value : '$1'.

Directive -> include string : {'$include', value_of('$2')}.

Key -> atom : value_of('$1').
Key -> string : iolist_to_binary(value_of('$1')).

Value -> bool : value_of('$1').
Value -> atom : value_of('$1').
Value -> integer : value_of('$1').
Value -> float : value_of('$1').
Value -> string : iolist_to_binary(value_of('$1')).
Value -> percent : value_of('$1').
Value -> bytesize : value_of('$1').
Value -> duration : value_of('$1').
Value -> variable : value_of('$1').
Value -> Array : '$1'.
Value -> Object : '$1'.

Erlang code.

value_of(Token) -> element(3, Token).

