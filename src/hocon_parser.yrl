Nonterminals hocon array element elements object members member.

Terminals '{' '}' '[' ']' ',' ':' '=' bool atom integer float string bytesize duration.

Rootsymbol hocon.

hocon -> element : '$1'.

object -> '{' members '}' : {'$2'}.
object -> '{' '}' : {[]}.

members -> member ',' members : ['$1' | '$3'].
members -> member : ['$1'].

member -> atom ':' element : {element(3, '$1'),'$3'}.
member -> atom '=' element : {element(3, '$1'),'$3'}.
member -> string ':' element : {iolist_to_binary(element(3, '$1')),'$3'}.
member -> string '=' element : {iolist_to_binary(element(3, '$1')),'$3'}.

array -> '[' elements ']' : '$2'.
array -> '[' ']' : [].

elements -> element ',' elements : ['$1' | '$3'].
elements -> element : ['$1'].

element -> bool : element(3, '$1').
element -> atom : element(3, '$1').
element -> integer : element(3, '$1').
element -> float : element(3, '$1').
element -> string : iolist_to_binary(element(3, '$1')).
element -> bytesize : element(3, '$1').
element -> duration : element(3, '$1').
element -> array : '$1'.
element -> object : '$1'.
