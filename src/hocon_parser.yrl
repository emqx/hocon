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
hocon -> '{' fields endobj : '$2'.
hocon -> fields : '$1'.

partials -> partial partials : ['$1' | '$2'].
partials -> endstr : [str_to_bin(map('$1'))].
partials -> endvar : [map('$1')].
partials -> '{' fields endobj : [{'$2'}].
partials -> '[' elements endarr : ['$2'].
partials -> '{' endobj : [{}].
partials -> '[' endarr : [].

partial -> string : str_to_bin(map('$1')).
partial -> variable : map('$1').
partial -> '{' fields '}' : {'$2'}.
partial -> '{' '}' : {[{}]}.
partial -> '[' elements ']' : '$2'.
partial -> '[' ']' : [].

fields -> field ',' fields : ['$1'|'$3'].
fields -> field fields : ['$1'|'$2'].
fields -> field : ['$1'].

field -> key value : {map('$1'), '$2'}.
field -> directive : '$1'.

elements -> value ',' elements : ['$1'|'$3'].
elements -> value elements : ['$1'|'$2'].
elements -> value : ['$1'].

directive -> include string : map_include('$2', false).
directive -> include endstr : map_include('$2', false).
directive -> include required string : map_include('$3', true).
directive -> include required endstr : map_include('$3', true).

value -> null : map('$1').
value -> bool : map('$1').
value -> integer : map('$1').
value -> float : map('$1').
value -> percent : map('$1').
value -> bytesize : map('$1').
value -> duration : map('$1').
value -> partials : maybe_concat('$1').

Erlang code.

map({endstr, Line, Value}) -> map({string, Line, Value});
map({endvar, Line, Value}) -> map({variable, Line, Value});
map({variable, Line, {maybe, Value}}) -> #{type => variable, line => Line, value => Value, required => false};
map({Type, Line, Value}) -> #{type => Type, line => Line, value => Value, required => true}.

map_include({_, Line, Value}, true) ->  #{type => include, line => Line, value => Value, required => true};
map_include({_, Line, Value}, false) ->  #{type => include, line => Line, value => Value, required => false}.

maybe_concat([]) -> [];
maybe_concat(S) -> {concat, S}.

str_to_bin(#{type := T, value := V} = M) when T =:= string -> M#{value => iolist_to_binary(V)}.
