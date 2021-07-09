# HOCON schema

HOCON schema is a type-safe data validation framework inspired
by [basho cuttlefish](https://github.com/basho/cuttlefish)

## Types

There are two high level kinds of data types defined in HOCON schema: `primitve` and `complex`.
If we think of Erlang data structure as a 'tree', then `primitive` types denote the 'leaves'
of the 'tree'. aka the terminal values.
While the `complex` types denote the values which enclose either other `complex` or `primitive` values.

### Primitive types

Most of the `primitive` types are provided by (and also can be extended from) the [typerefl](https://github.com/k32/typerefl) library.
Typerefl is highly composible hence can be used to define complex types.
However in HOCON schema we only use it to define `primitive` types.

Here is a list of the `primitive` types for reference:

* enum: Enum is a list of Erlang atoms
* singleton: singleton is an Erlang atom
* integer: typerefl:integer()
* string: typerefl:integer()

And an extended primitive type example: `ip_port`

```
-type ip_port() :: tuple().
-typerefl_from_string({ip_port/0, this_module, to_ip_port}).
to_ip_port(String) ->
    case string:tokens(String) of
        ....
    end.
```

### Complex types

HOCON schema supports 3 different complext types: `struct`, `array`, and `union`.
NOTE: to make it easier for future extensions, it's recommended to use `hoconsc` module APIs to define schema.

#### Structs

NOTE: HOCON schema does not support non-struct root level data types. e.g. it is not allowed to
define a root level schema with just a `integer()` type.

Structs consist of data fields, which can be defined using `hocon_schema` behaviour callbacks.

* `structs/0`: This callback returns all the root level namespaces.
* `fields/1`: THis callback returns the schema for each data field (in a list, so order matters).

For example, to define a struct named `foo` having one integer field, the schema module may look like:

```
-export([structs/0, fields/1]).
structs() -> ["foo"]. %% 'exported' root names
fields("foo") -> [{"field1", typerefl:integer()}].
```

In this case, the schema for use in `hocon_schema` APIs is the module name. There is another way to
define a struct as a Erlang `map()`, so we do not have to implement the behaviour callbacks
(this is however mostly for test cases):

```
#{structs => ["foo"], %% 'exported' root names
  fields => #{"foo" => [{"field1", typerefl:integer()}]}
 }
```

##### Struct references

In order to promote code abstraction and prevent copy-paste as much as possible,
in HOCON schema, there is no way to define structs nested (child struct nested in a parent struct).
The parent-children relationship has to be defined as struct 'referencing'.

e.g. if the type of parent-struct's field is another struct, the field's type should be defined as:

```
[ ...,
  {field_N, hoconsc:ref("field_struct_name")},
  ...
].
```

##### Virtual struct root

The root struct name exported in the `structs/0` API serves as top level struct's field names.
like `listener`, `zone` and `broker` in `etc/emqx.conf`.

#### Arrays

Array is a sequence of other types which is defined as `{array, Type}`.

#### Unions

A union type is in some contexts `one_of` types.
When data is validated against the schema (recursively), the code enumerates
the union member types in the defined order until the given data matches any of the union member.

### Config generation

When starting a Erlang node it requires a system configuration file, (usually named `sys.config`),
see [Erlang doc](https://erlang.org/doc/man/config.html#sys.config) for more details.

When using HOCON config format, we need a tool to tranfrom a HOCON file to a config file of `sys.config` format.
`hocon_schema` is such a tool.

### Config mapping

As introduced above, Erlang requires a `sys.config` to bootstrap, the content of this config is essentially
an Erlang expression which evaluates to an Erlang term (the 'object' in Erlang).

To map HOCON objects (or their fields) to Erlang terms, we need to define a set of rules, such rules in HOCON schema
is called 'mapping' rules.

This is when we need to introduce metadata to struct fields' schema.

The way to define a 'mapping' metadata is like below:

```
fields("struct_foo") ->
  [ {field1, #{type => integer(),
               mapping => "app_foo.field1"
              }
  ]
```

This should map HOCON config `{struct_foo: {field1: 12}}` to `sys.config` like `[{app_foo, [{field1, 12}]}]`.

### Config translation

Sometimes it's impossible to perform a perfect mapping from HOCON object to Erlang term.
This is when `translation` is used.

Translations are defined as callback too, for example, if we want to translate
to config entries named 'min' and 'max' into a range tuple in `sys.config`,
this schema below should do it.

```
-module(myapp_schema).

translation("foo") ->
  [{"range", fun range/1}].

range(Conf) ->
    Min = hocon_schema:deep_get("foo.min", Conf, value),
    Max = hocon_schema:deep_get("foo.max", Conf, value),
    case Min < Max of
        true ->
            {Min, Max};
        _ ->
            undefined
    end.
```

As in the example, a translation callback is provided with the global config,
specific field values can be retrieved with `hocon_schema:deep_get` API.

### Config integrity validation

Inter-field or even inter-object config validation can be done by implementing
the `validations` optional callback.
Validations work similar to translations, only the OK return value is discarded
and failures are raised as exception in the map call.

NOTE: the integrity validation is performed after all fields are checked and coverted.

Below is an example to ensure that the `min` field is never greater than `max` field.

```
-module(myapp_schema).

validations() ->
  [{"min =< max", fun min_max/1}].

min_max(Conf) ->
    Min = hocon_schema:deep_get("foo.min", Conf, value),
    Max = hocon_schema:deep_get("foo.max", Conf, value),
    case Min =< Max of
        true -> ok %% return true | ok to pass this validation
        false -> "min > max is not allowed"
    end.
```

## Struct field metadata

Besides fields' `mapping` metadata, which is introduced above, for config mapping,
HOCON schema also supports below field metadata.

* `converter`: an anonymous function evaluated during config generation to convert the field value.
* `validator`: field value validator, an anonymous function which should return `true` or `ok` if
  the value is as expected. NOTE: the input to validator after convert (if present) is applied.
* `default`: default value of the field. NOTE that default values are to be treated as raw inputs,
  meaning they are put hrough  the `converter`s and `validator`s etc, and then type-checked.
* `override_env`: special environment variable name to override this field value.
  NOTE: For generic override, see [below](#default_override_rule) for more info
* `nullable`: set to `true` if this field is allowed to be `undefined`.
  NOTE: there is no point setting it to `true` if fields has a default value.
* `sensitive`: set to `true` if this field's value is sensitive so we will obfuscate the log
  with `********` when logging.

<a name="default_override_rule"></a>
## Default environment variable override

By default, a field (except for when it's inside an array element) can be overriden by an environment
variable the name of which is translated from field's absolute path with dots replaced by
double-underscores and then prepended with a prefix.

For example, the value of config entry `foo.bar.field1` can be overriden by
`PREFIX_FOO__BAR__FIELD1`, or `PREFIX_foo_bar_field1`, where `PREFIX_`
is configurable by another environment variable `HOCON_ENV_OVERRIDE_PREFIX`.

