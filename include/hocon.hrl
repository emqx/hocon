-define(IS_VALUE_LIST(T), (T =:= array orelse T =:= concat orelse T =:= object)).
-define(IS_FIELD(F), (is_tuple(F) andalso size(F) =:= 2)).

-define(SECOND, 1000).
-define(MINUTE, (?SECOND*60)).
-define(HOUR,   (?MINUTE*60)).
-define(DAY,    (?HOUR*24)).
-define(WEEK,      (?DAY*7)).
-define(FORTNIGHT, (?WEEK*2)).

-define(KILOBYTE, 1024).
-define(MEGABYTE, (?KILOBYTE*1024)). %1048576
-define(GIGABYTE, (?MEGABYTE*1024)). %1073741824
