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
  string variable
  endstr endvar endarr endobj
  include key required.

Rootsymbol hocon.
hocon -> '{' fields endobj : make_object(0, '$2').
hocon -> fields : make_object(0, '$1').

partials -> partial partials : ['$1' | '$2'].
partials -> endstr : [str_to_bin(make_primitive_value('$1'))].
partials -> endvar : [make_variable('$1')].
partials -> '{' fields endobj : [make_object(line_of('$1'), '$2')].
partials -> '[' elements endarr : [make_array(line_of('$1'), '$2')].
partials -> '{' endobj : [make_object(line_of('$1'), [])].
partials -> '[' endarr : [make_array(line_of('$1'), [])].

partial -> string : str_to_bin(make_primitive_value('$1')).
partial -> variable : make_variable('$1').
partial -> '{' fields '}' : make_object(line_of('$1'), '$2').
partial -> '{' '}' : make_object(line_of('$1'), []).
partial -> '[' elements ']' : make_array(line_of('$1'), '$2').
partial -> '[' ']' : make_array(line_of('$1'), []).

fields -> field ',' fields : ['$1' | '$3'].
fields -> field fields : ['$1' | '$2'].
fields -> field : ['$1'].

field -> key value : {make_primitive_value('$1'), '$2'}.
field -> directive : '$1'.

elements -> value ',' elements : ['$1' | '$3'].
elements -> value elements : ['$1' | '$2'].
elements -> value : ['$1'].

directive -> include string : make_include('$2', false).
directive -> include endstr : make_include('$2', false).
directive -> include required string : make_include('$3', true).
directive -> include required endstr : make_include('$3', true).

value -> null : make_primitive_value('$1').
value -> bool : make_primitive_value('$1').
value -> integer : make_primitive_value('$1').
value -> float : make_primitive_value('$1').
value -> percent : make_primitive_value('$1').
value -> bytesize : make_primitive_value('$1').
value -> duration : make_primitive_value('$1').
value -> partials : make_concat('$1').

Erlang code.

make_object(Line, Object) -> #{type => object, value => Object, metadata => #{line => Line}}.

make_array(Line, Array) -> #{type => array, value => Array, metadata => #{line => Line}}.

make_primitive_value({endstr, Line, Value}) -> #{type => string, value => Value, metadata => #{line => Line}};
make_primitive_value({T, Line, Value}) -> #{type => T, value => Value, metadata => #{line => Line}}.

make_variable({V, Line, {maybe, Value}}) when V =:= variable orelse V =:= endvar ->
    #{type => variable, value => Value, name => Value, metadata => #{line => Line}, required => false};
make_variable({V, Line, Value}) when V =:= variable orelse V =:= endvar ->
    #{type => variable, value => Value, name => Value, metadata => #{line => Line}, required => true}.

make_include(String, true) ->  #{type => include,
                                 value => bin(value_of(String)),
                                 metadata => #{line => line_of(String)},
                                 required => true};
make_include(String, false) ->  #{type => include,
                                  value => bin(value_of(String)),
                                  metadata => #{line => line_of(String)},
                                  required => false}.

make_concat(S) -> #{type => concat, value => S}.

str_to_bin(#{type := T, value := V} = M) when T =:= string -> M#{value => bin(V)}.

line_of(Token) -> element(2, Token).
value_of(Token) -> element(3, Token).

bin(Value) -> iolist_to_binary(Value).
