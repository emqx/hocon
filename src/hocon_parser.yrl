Nonterminals
  Hocon
  Array
  Object
  Members
  Member
  Elements
  Element
  Value.

Terminals
  '{' '}' '[' ']' ',' ':' '=' '\n'
   bool atom integer float string
   bytesize duration.

Rootsymbol Hocon.

Hocon -> Members : '$1'.
Hocon -> Element : '$1'.

Object -> '{' Members '}' : {'$2'}.
Object -> '{' '}' : {[]}.

Members -> Member ',' Members : ['$1'|'$3'].
Members -> Member '\n' Members : ['$1'|'$3'].
Members -> Member : ['$1'].

Member -> atom ':' Element : {element(3, '$1'), '$3'}.
Member -> atom '=' Element : {element(3, '$1'), '$3'}.
Member -> string ':' Element : {iolist_to_binary(element(3, '$1')), '$3'}.
Member -> string '=' Element : {iolist_to_binary(element(3, '$1')), '$3'}.

Array -> '[' Elements ']' : '$2'.
Array -> '[' ']' : [].

Elements -> Element ',' Elements : ['$1'|'$3'].
Elements -> Element : ['$1'].

Element -> Value: '$1'.

Value -> bool : element(3, '$1').
Value -> atom : element(3, '$1').
Value -> integer : element(3, '$1').
Value -> float : element(3, '$1').
Value -> string : iolist_to_binary(element(3, '$1')).
Value -> bytesize : element(3, '$1').
Value -> duration : element(3, '$1').
Value -> Array : '$1'.
Value -> Object : '$1'.

