%% This module contains all CPL script parsing functions that can 
%% easily be tested independently of the main parse function in 
%% xml_parse.erl
%%--------------------------------------------------------------------

-module(xml_parse_util).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 date/1,
	 time/1,
	 parse_until/1,
	 parse_byday/1,
	 duration/1,
	 iolist_to_str/1,
	 check_range/2,
	 legal_value/2,
	 status_code_to_sip_error_code/1,
	 normalize_prio/1,
	 is_language_range/1,
	 is_language_tag/1,

	 visualize/1,
	 test/0
	]).

%%--------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

-include("cpl.hrl").
-include("xml_parse.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------

%%====================================================================
%% External functions
%%====================================================================
           
%%--------------------------------------------------------------------
%% Function: date(DateString)
%% Descrip.: parse a CPL DATE string
%% Returns : {Year, Month, Day} | throw()
%%
%% Function: time(DateTimeString)
%% Descrip.: parse a CPL DATE-TIME string
%% Returns : date_time record() | throw()
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% BNF     :
%%
%% RFC 2445 chapter 4.3.4
%% 
%% date               = date-value
%%
%% date-value         = date-fullyear date-month date-mday
%% date-fullyear      = 4DIGIT
%% date-month         = 2DIGIT        ;01-12
%% date-mday          = 2DIGIT        ;01-28, 01-29, 01-30, 01-31
%%                                    ;based on month/year
%%
%% RFC 2445 chapter 4.3.12
%% time               = time-hour time-minute time-second [time-utc]
%%
%% time-hour          = 2DIGIT        ;00-23
%% time-minute        = 2DIGIT        ;00-59
%% time-second        = 2DIGIT        ;00-60
%% ;The "60" value is used to account for "leap" seconds.
%%
%% time-utc   = "Z"
%%
%% RFC 2445 chapter 4.3.5
%% date-time  = date "T" time ;As specified in the date and time
%%                            ;value definitions
%%--------------------------------------------------------------------
date([Y1,Y2,Y3,Y4,M1,M2,D1,D2]) ->
    try 
	begin
	    Year = list_to_integer([Y1,Y2,Y3,Y4]),
	    Month = list_to_integer([M1,M2]),
	    Day = list_to_integer([D1,D2]),
	    case calendar:valid_date(Year, Month, Day) of
		true -> ok;
		false ->
		    throw({error, out_of_range_date_value_used})
	    end,
	    {Year, Month, Day}
	end
    catch
	error: _ ->
	    throw({error, non_numerical_date_value_used})
    end;
    
date(_) ->
    throw({error, malformed_date_attribute_value}).



time([_Y1,_Y2,_Y3,_Y4,_M1,_M2,_D1,_D2,$t,_H1,_H2,_Min1,_Min2,_S1,_S2 | R] = Time) ->
    time2(Time, time_type(R));

time([_Y1,_Y2,_Y3,_Y4,_M1,_M2,_D1,_D2,$T,_H1,_H2,_Min1,_Min2,_S1,_S2| R] = Time) ->
    time2(Time, time_type(R));

time(_) ->
    throw({error, malformed_date_time_attribute_value}).

time_type([]) -> floating;
time_type([$Z]) -> utc;
time_type([$z]) -> utc;
time_type(_) -> throw({error, time_utc_marker_is_not_a_z}).

time2([Y1,Y2,Y3,Y4,M1,M2,D1,D2,_,H1,H2,Min1,Min2,S1,S2 | _], Type) ->
    try
	begin
	    Year = list_to_integer([Y1,Y2,Y3,Y4]),
	    Month = list_to_integer([M1,M2]),
	    Day = list_to_integer([D1,D2]),
	    Hour = list_to_integer([H1,H2]),
	    Minute = list_to_integer([Min1,Min2]),
	    Second = list_to_integer([S1,S2]),
	    
	    %% check that time is legal 
	    %% Note: leap seconds need to be handled or set to 59 by 
	    %%       other cpl modules that use date_time record()
	    case calendar:valid_date(Year, Month, Day) and
		(Hour >= 0) and (Hour =< 23) and
		(Minute >= 0) and (Minute =< 59) and
		(Second >= 0) and (Second =< 60) of
		true -> ok;
		false ->
		    throw({error, out_of_range_date_time_value_used})
	    end,
	    #date_time{date = {Year, Month, Day}, time = {Hour, Minute, Second}, type = Type}
	end
    catch
	error: _ ->
	    throw({error, non_numerical_date_time_value_used})
    end.

%%--------------------------------------------------------------------
%% Function: parse_until(UntilStr)
%%           UntilStr = string(), the value of a until attribute in a
%%           time tag in a time-switch
%% Descrip.: "The "until" parameter defines an iCalendar COS DATE or 
%%           DATE-TIME [COS DATE or COS DATE-TIME] value which bounds
%%           the recurrence rule in an inclusive manner.
%%           [.....] If specified as a date-time value, then it MUST 
%%           be specified in UTC time format."
%%           - RFC 3880 chapter 4.4 p16 
%%           This function parses the until value in time tag in a 
%%           time-switch tag
%% Returns : {Year, Month, Date} | date_time record() | throw()    
%%--------------------------------------------------------------------
parse_until(UntilStr) ->
    try time(UntilStr) of
	#date_time{type = utc} = DateTime -> 
	    DateTime;
	_ -> 
	    throw({error, data_time_must_be_in_utc_format})
    catch
	throw: _ -> 
	    date(UntilStr)
    end.

%%--------------------------------------------------------------------
%% Function: parse_byday(Str)
%%           Str = string(), content of a byday attribute
%% Descrip.: process the content of the byday attribute in the time 
%%           tag used by the time-switch tag
%% Returns : list() of {N, Day} 
%%           Day = mo | tu | we | th | fr | sa | su
%%           N = -1 or less | 1 or greater | 
%%               all (default, if no +N or -N is used) 
%%--------------------------------------------------------------------
parse_byday(Str) ->
    Days = string:tokens(httpd_util:to_lower(Str), ","),
    F = fun
	    ("mo") -> {all, mo};
	    ("tu") -> {all, tu};
	    ("we") -> {all, we};
	    ("th") -> {all, th};
	    ("fr") -> {all, fr};
	    ("sa") -> {all, sa};
	    ("su") -> {all, su};
	    ("+" ++ ND) -> get_day(ND);
	    ("1" ++ ND) -> get_day("1" ++ ND);
	    ("2" ++ ND) -> get_day("2" ++ ND);
	    ("3" ++ ND) -> get_day("3" ++ ND);
	    ("4" ++ ND) -> get_day("4" ++ ND);
	    ("5" ++ ND) -> get_day("5" ++ ND);
	    ("6" ++ ND) -> get_day("6" ++ ND);
	    ("7" ++ ND) -> get_day("7" ++ ND);
	    ("8" ++ ND) -> get_day("8" ++ ND);
	    ("9" ++ ND) -> get_day("9" ++ ND);
	    ("-" ++ ND) -> 
		{DayNo, Day} = get_day(ND),
		{-DayNo, Day};
	    (_) -> throw({error, byday_attribute_value_not_a_day})
	end,
    %% lists:sort([F(E) || E <- Days]).
    [F(E) || E <- Days].

%% descrip.: 
%% return  : {DayNumber, Day}
%%           Number = integer()
%%           Day = mo | tu | we | th | fr | sa | su
get_day(Str) ->
    get_day(Str, []).

%% accumulate number of days
get_day([C | R], Acc) when C >= $0, C =< $9 ->
    get_day(R, [C | Acc]);
%% last two chars must be the day code 
get_day([D1,D2], Acc) ->
    DayNo = list_to_integer(lists:reverse(Acc)),
    Day = [D1,D2],
    case Day of
	"mo" -> {DayNo, mo}; 
	"tu" -> {DayNo, tu};
	"we" -> {DayNo, we};
	"th" -> {DayNo, th};
	"fr" -> {DayNo, fr};
	"sa" -> {DayNo, sa};
	"su" -> {DayNo, su};
	_ -> throw({error, byday_attribute_incorrect_day_flag})
    end;
get_day(_, _Acc) ->
    throw({error, byday_attribute_premature_end_of_day_entry}).

%%--------------------------------------------------------------------
%% Function: duration(DurationString)
%% Descrip.: parse a CPL DURATION string
%% Returns : duration record()
%% Note    : is there a range limit on the time value, e.g. 
%%           dur-second = range "00S" - "59S" ?
%%           probably - but cpl handles unlimited ranges
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% RFC 2445 chapter 4.3.6 p36
%% 
%% Duration: 
%%
%% dur-value  = (["+"] / "-") "P" (dur-date / dur-time / dur-week)
%%
%% dur-date   = dur-day [dur-time]
%% dur-time   = "T" (dur-hour / dur-minute / dur-second)
%% dur-week   = 1*DIGIT "W"
%% dur-hour   = 1*DIGIT "H" [dur-minute]
%% dur-minute = 1*DIGIT "M" [dur-second]
%% dur-second = 1*DIGIT "S"
%% dur-day    = 1*DIGIT "D"
%%
%% Note: "Zero-length and negative-length durations are not allowed."
%% - RFC 3880 chapter 4.4 p16
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% This can be rewritten as:
%% Duration = "P" | "+P" | "-P"        ; followed by the following possibilities
%%
%% 1*DIGIT "D" "T" 1*DIGIT "H" [dur-minute]
%% 1*DIGIT "D" "T" 1*DIGIT "M" [dur-second]
%% 1*DIGIT "D" "T" 1*DIGIT "S"
%% "T" 1*DIGIT "H" [dur-minute]
%% "T" 1*DIGIT "M" [dur-second]
%% "T" 1*DIGIT "S"
%% 1*DIGIT "W"
%%--------------------------------------------------------------------

duration(Str) ->
    case duration2(httpd_util:to_lower(Str), #duration{}) of
	#duration{weeks = 0, days = 0, hours = 0, minutes = 0, seconds = 0} ->
	    throw({error, duration_value_may_not_be_zero_length});
	Duration ->
	    Duration
    end.
    
duration2("p" ++ R, D) -> duration3(R, D);
duration2("+p" ++ R, D) -> duration3(R, D);
duration2("-p" ++ _R, _D) -> throw({error, duration_value_may_not_be_negativ}).

%% "..PT..."
duration3("t" ++ _R = Str, D) ->
    duration_t(Str, D);
%% "..PxxxDT..." or "..PxxxW"
duration3(R, D) -> 
    {Type, Num, Rest} = get_digit(R),
    case Type of
	$w -> case Rest of
		  [] -> D#duration{weeks = Num};
		  _ -> throw({error, duration_has_trailing_chars_after_week_entry})
	      end;
	$d -> D2 = D#duration{days = Num},
	      duration_t(Rest, D2);
	_ -> throw({error, duration_expected_PxxxDTyyy_or_PxxxW_format})
    end.

duration_t("t" ++ R, D) -> 
    {Type, Num, Rest} = get_digit(R),
    case {Type, Rest} of
	{$h,[]} -> D#duration{hours = Num};
	{$m,[]} -> D#duration{minutes = Num};
	{$s,[]} -> D#duration{seconds = Num};
	{$h,_} -> D2 = D#duration{hours = Num}, 
		  duration_m(Rest, D2);
	{$m,_} -> D2 = D#duration{minutes = Num}, 
		  duration_s(Rest, D2);
	{$s,_} -> throw({error, duration_has_trailing_chars_after_second_entry});
	_ -> throw({error, duration_expected_M_H_or_S_after_the_T})
    end.

duration_m(R, D) -> 
    {Type, Num, Rest} = get_digit(R),
    case {Type, Rest} of
	{$m, []} -> D#duration{minutes = Num};
	{$m, _} -> D2 = D#duration{minutes = Num},
		   duration_s(Rest, D2);
	_ -> throw({error, duration_expected_M_after_the_H})
    end.

duration_s(R, D) -> 
    {Type, Num, Rest} = get_digit(R),
    case {Type, Rest} of
	{$s, []} -> D#duration{seconds = Num};
	{$s, _} -> throw({error, duration_missing_period_type_indicator_after_second_digit});
	_ -> throw({error, duration_expected_S_after_the_M})
    end.

%% descrip.: 
%% return  : {Type, Number, StrRest}
%%           Type = $h | $m | $s | $w | $d
%%           Number = integer()
%%           StrRest = string() the rest of Str after Number-Type chars 
get_digit(Str) ->
    get_digit(Str, []).

get_digit([], _Acc) ->
    throw({error, duration_missing_period_type_indicator_after_digit});
get_digit([C | R], Acc) when C >= $0, C =< $9 ->
    get_digit(R, [C | Acc]);
get_digit([Type | R], Acc) ->
    {Type, list_to_integer(lists:reverse(Acc)), R}.


%%--------------------------------------------------------------------
%% Function: iolist_to_str(IOlist)
%% Descrip.: "An I/O list is a deep list of binaries, integers in the
%%           range 0 through 255, and other I/O lists. In an I/O list,
%%           a binary is allowed as the tail of a list." - erlang 
%%           module documentation (R10B)
%%           This function converts a iolist to a flat list (string())
%%           so that they are easier to handle when doing various 
%%           forms of parsing on the text
%% Returns : string()                                                   XXX put this in a utility module
%% Note    : binaries are assumed to be "strings" i.e. each byte = a 
%%           char value.
%%--------------------------------------------------------------------
iolist_to_str(IOList) when list(IOList) ->
    %% this relies on lists being flattened when they are turned to
    %% binaries. Both functions are bifs which probably makes this the
    %% fastest solution.
    binary_to_list(list_to_binary(IOList)).


%%--------------------------------------------------------------------
%% Function: check_range(Val, {L1, L2})
%%           check_range(Val, L)
%%           Val        = integer()
%%           L, L1, L2  = [Val1, Val2], specifies a range (order of 
%%                        start and end doesn't matter)
%%           Val1, Val2 = integer()
%% Descrip.: check if Val is part of range LN, either one or two 
%%           ranges are checked 
%% Returns : Val | throw()
%%--------------------------------------------------------------------
check_range(Val, {L1, L2}) ->
    case check_range(Val, L1) or check_range(Val, L2) of
	true -> Val;
	false -> throw({error, value_out_of_range})

    end;

check_range(Val, L) when is_list(L) ->
    [Min, Max] = lists:sort(L),
    (Val >= Min) and (Val =< Max).

%%--------------------------------------------------------------------
%% Function: legal_value(Value, LegalValues)
%%           Value       = term()
%%           legalValues = term()
%% Descrip.: throw a exception if Value isn't part of LegalValues
%% Returns : ok | throw()
%%--------------------------------------------------------------------
legal_value(Value, LegalValues) ->
    case lists:member(Value, LegalValues) of
	true ->
	    ok;
	false ->
	    throw({error, attribute_value_is_not_legal})
    end.

%%--------------------------------------------------------------------
%% Function: status_code_to_sip_error_code(Status)
%%           Status = string(), the value of the status attribute in
%%           a reject tag
%% Descrip.: return the numerical error code of Status
%% Returns : integer() | throw(), if numerical error code out of range
%%           or unkown symbolic name is used
%% Note    : other protocols than sip/sips may require additional 
%%           error codes
%% XXX should return be integer(), this may pose problems for protocols with non-numeric error codes ? 
%%--------------------------------------------------------------------
status_code_to_sip_error_code(Status) ->
    case util:isnumeric(Status) of
	%% SIP specific error codes
	true -> NumStatus = list_to_integer(Status),
		case (NumStatus >= 400) and (NumStatus =< 699) of
		    true -> NumStatus;
		    false -> throw({error, sip_error_code_must_be_in_the_4xx_5xx_or_6xx_range})
		end;
	%% mandatory CPL error codes
	false ->
	    case Status of
		"busy" -> 486;     % Busy Here
		"notfound" -> 404; % Not Found
		"reject" -> 603;   % Decline
		"error" -> 500;    % Internal Server Error
		_ -> throw({error, reject_tag_status_attribute_value_not_recognised_as_status_code})
	    end
    end.    

%%--------------------------------------------------------------------
%% Function: normalize_prio(PrioStr)
%% Descrip.: convert priority values used by priority-switch in the 
%%           attributes (less, greater, equal) of priority, to a 
%%           standard atom() format
%% Returns : emrengency | urgent | normal | 'non-urgent' | 
%%           {unkown, PrioStr}    - RFC 3880 chapter 4.5 p21 and 
%%           RFC 3261 chapter 20.26 p173 allow for additional priority 
%%           values beyond "non-urgent", "normal", "urgent", and 
%%           "emergency"
%%--------------------------------------------------------------------
normalize_prio(PrioStr) ->
    case httpd_util:to_lower(PrioStr) of
	"emergency" -> emergency;
	"urgent" -> urgent;
	"normal" -> normal;
	"non-urgent" -> 'non-urgent';
	_ -> {unknown, PrioStr}
    end.

%%--------------------------------------------------------------------
%% RFC 3066
%% Language-Tag = Primary-subtag *( "-" Subtag )
%% Primary-subtag = 1*8ALPHA
%% Subtag = 1*8(ALPHA / DIGIT)
%%
%% language-range  = language-tag / "*"
%%--------------------------------------------------------------------
%% Function: is_language_range(Str) 
%%           is_language_tag(Str)
%%           Str = string() 
%% Descrip.: determine if Str is a language-range (or language-tag)
%% Returns : string() | throw()
%%--------------------------------------------------------------------
%% throw() if language is malformed, otherwise return Str
is_language_range("*") ->
    "*";
is_language_range(Str) ->
    is_language_tag(Str, range).

is_language_tag(Str) ->
    is_language_tag(Str, tag).
is_language_tag(Str, Type) ->
    Pattern = 
	"^([a-zA-Z][a-zA-Z]?[a-zA-Z]?[a-zA-Z]?[a-zA-Z]?[a-zA-Z]?[a-zA-Z]?[a-zA-Z]?)"
	"(-[a-zA-Z1-9][a-zA-Z1-9]?[a-zA-Z1-9]?[a-zA-Z1-9]?"
	"[a-zA-Z1-9]?[a-zA-Z1-9]?[a-zA-Z1-9]?[a-zA-Z1-9]?)*$",
    case regexp:first_match(Str, Pattern) of
	{match, _, _} ->
	    Str;
	_ ->case Type of
		tag -> 
		    throw({error, malformed_language_tag});
		range ->
		    throw({error, malformed_language_range})
	    end
    end.

%%====================================================================
%% Behaviour functions
%%====================================================================

%%====================================================================
%% Internal functions
%%====================================================================

%%====================================================================
%% Test functions
%%====================================================================

%% debug help function
visualize(ParseState) when record(ParseState, parse_state) ->
    G = ParseState#parse_state.current_graph,
    visualize(G);

visualize(G) ->
    Es = digraph:edges(G),
    Vs = digraph:vertices(G),
    Ns = [digraph:vertex(G, V) || V <- Vs],
    io:format("Edges    = ~p~n",[Es]),
    io:format("Vertices = ~p~n",[Vs]),
    io:format("Nodes    = ~p~n",[Ns]).


%%--------------------------------------------------------------------
%% Function:
%% Descrip.: autotest callback
%% Returns :
%%--------------------------------------------------------------------
test() ->

    %% time/1
    %%--------------------------------------------------------------------
    %% normal, floating
    io:format("test: time/1  - 1~n"),
    #date_time{date = {1953, 12, 24}, time = {12, 53, 43}, type = floating} = time("19531224T125343"),

    %% normal, utc (lower and upper case)
    io:format("test: time/1  - 2~n"),
    #date_time{date = {1953, 12, 24}, time = {12, 53, 43}, type = utc} = time("19531224t125343Z"),
    #date_time{date = {1953, 12, 24}, time = {12, 53, 43}, type = utc} = time("19531224t125343z"),

    %% out of range date or time - month
    io:format("test: time/1  - 3.1~n"),
    autotest:fail(fun() -> time("19531324t125343Z") end),

    %% out of range date or time - day
    io:format("test: time/1  - 3.2~n"),
    autotest:fail(fun() -> time("19531234t125343Z") end),

    %% out of range date or time - hour
    io:format("test: time/1  - 3.3~n"),
    autotest:fail(fun() -> time("19531224t245343Z") end),

    %% out of range date or time - minut
    io:format("test: time/1  - 3.4~n"),
    autotest:fail(fun() -> time("19531224t126343Z") end),

    %% out of range date or time - second
    io:format("test: time/1  - 3.5~n"),
    autotest:fail(fun() -> time("19531224t125363Z") end),
    
    %% non-existent date
    io:format("test: time/1  - 4.1~n"),
    autotest:fail(fun() -> time("20040230t125343Z") end),
    io:format("test: time/1  - 4.2~n"),
    autotest:fail(fun() -> time("20040431t125343Z") end),
    io:format("test: time/1  - 4.3~n"),
    autotest:fail(fun() -> time("20040631t125343Z") end),
    io:format("test: time/1  - 4.4~n"),
    autotest:fail(fun() -> time("20040931t125343Z") end),
    io:format("test: time/1  - 4.5~n"),
    autotest:fail(fun() -> time("20041131t125343Z") end),

    %% non-numerical date-time
    io:format("test: time/1  - 5~n"),
    autotest:fail(fun() -> time("200A1131t125343Z") end),

    %% parse_until/1
    %%--------------------------------------------------------------------
    %% test date format
    io:format("test: parse_until/1  - 1~n"),
    {1998, 10, 24} = parse_until("19981024"),

    %% test date-time format
    io:format("test: parse_until/1  - 2~n"),
    #date_time{date = {1953, 12, 24}, time = {12, 53, 43}, type = utc} = parse_until("19531224t125343Z"),

    %% test that date-time without utc fails
    io:format("test: parse_until/1  - 3~n"),
    autotest:fail(fun() -> parse_until("19531224t125343") end),

    %% non-existent date
    io:format("test: parse_until/1  - 4~n"),
    autotest:fail(fun() -> parse_until("20040230") end),
    io:format("test: parse_until/1  - 5~n"),
    autotest:fail(fun() -> parse_until("20040431") end),
    io:format("test: parse_until/1  - 6~n"),
    autotest:fail(fun() -> parse_until("20040631") end),
    io:format("test: parse_until/1  - 7~n"),
    autotest:fail(fun() -> parse_until("20040931") end),
    io:format("test: parse_until/1  - 8~n"),
    autotest:fail(fun() -> parse_until("20041131") end),

    %% parse_byday/1
    %%--------------------------------------------------------------------
    %% test sequence of days
    io:format("test: parse_byday/1  - 1~n"),
    L1 = [{all,mo}, {all,we}, {all,fr}],
    L1 = parse_byday("mo,we,fr"),

    %% test case handling
    io:format("test: parse_byday/1  - 2~n"),
    L2 = [{all,mo}, {all, we}, {all, fr}],
    L2 = parse_byday("Mo,wE,FR"),

    %% test support for +/-Ndd format
    io:format("test: parse_byday/1  - 3~n"),
    L3 = [{1,mo}, {-2, we}, {2, fr}],
    L3 = parse_byday("+1mo,-2we,2fr"),
    
    %% test empty byday
    io:format("test: parse_byday/1  - 4~n"),
    [] = parse_byday(""),

    %% test single entry byday
    io:format("test: parse_byday/1  - 5~n"),
    [{-2, sa}] = parse_byday("-2sa"),

    %% missing day
    io:format("test: parse_byday/1  - 6~n"),
    autotest:fail(fun() -> parse_byday("21") end),
    %% incorrect format
    io:format("test: parse_byday/1  - 7~n"),
    autotest:fail(fun() -> parse_byday("21foo") end),
    %% 'fo' isn't a day
    io:format("test: parse_byday/1  - 8~n"),
    autotest:fail(fun() -> parse_byday("21fo") end),


    %% duration/1
    %%--------------------------------------------------------------------
    %% test day-hour-min-sec
    io:format("test: duration/1  - 1~n"),
    #duration{weeks = 0, days = 15, hours = 5, minutes = 2, seconds = 20} = duration("P15DT5H2M20S"),
    #duration{weeks = 0, days = 15, hours = 5, minutes = 2, seconds = 0} = duration("P15DT5H2M"),
    #duration{weeks = 0, days = 15, hours = 5, minutes = 0, seconds = 0} = duration("P15DT5H"),
    
    %% test week
    io:format("test: duration/1  - 2~n"),
    #duration{weeks = 7, days = 0, hours = 0, minutes = 0, seconds = 0}  = duration("P7W"),
						
    %% test hour-min-sec
    io:format("test: duration/1  - 3~n"),
    #duration{weeks = 0, days = 0, hours = 5, minutes = 2, seconds = 20}  = duration("PT5H2M20S"),
    #duration{weeks = 0, days = 0, hours = 5, minutes = 2, seconds = 0}  = duration("PT5H2M"),
    #duration{weeks = 0, days = 0, hours = 5, minutes = 0, seconds = 0} = duration("PT5H"),

    %% usage of week disallows all other duration values 
    io:format("test: duration/1  - 4~n"),
    autotest:fail(fun() -> duration("P7W15D") end),
    autotest:fail(fun() -> duration("P7W15DT5H") end),
    
    %% negative or zero duration
    io:format("test: duration/1  - 5~n"),
    autotest:fail(fun() -> duration("-P15DT5H2M20S") end),
    autotest:fail(fun() -> duration("P0DT0H0M0S") end),

    %% use of "+" sign
    io:format("test: duration/1  - 6~n"),
    duration("+P15DT5H2M20S"),

    %% skip M in H-M-S sequence - should fail
    io:format("test: duration/1  - 7~n"),
    autotest:fail(fun() -> duration("P15DT5H20S") end),

    %% test case insensetivitiy
    io:format("test: duration/1  - 8~n"),
    #duration{weeks = 0, days = 15, hours = 5, minutes = 2, seconds = 20} = duration("p15dt5h2m20s"),
    #duration{weeks = 7, days = 0, hours = 0, minutes = 0, seconds = 0}  = duration("p7w"),
    #duration{weeks = 0, days = 15, hours = 5, minutes = 2, seconds = 20} = duration("p15Dt5H2m20S"),
    #duration{weeks = 7, days = 0, hours = 0, minutes = 0, seconds = 0} = duration("p7W"),



    %% iolist_to_str/1
    %%--------------------------------------------------------------------
    %% regular string
    io:format("test: iolist_to_str/1  - 1~n"),
    "hello world !" = iolist_to_str("hello world !"),
    
    %% binary
    io:format("test: iolist_to_str/1  - 2~n"),
    "hello world !" = iolist_to_str([<<"hello world !">>]),
				     
    %% char + binary
    io:format("test: iolist_to_str/1  - 3~n"),
    "hello world !" = iolist_to_str([$h, $e, $l, <<"lo world !">>]),

    %% nested binary (= one binary)
    io:format("test: iolist_to_str/1  - 4~n"),
    "hello world !" = iolist_to_str([<< <<"hello">>/binary, <<" world !">>/binary >>]),

    %% nesting binary, chars and lists 
    io:format("test: iolist_to_str/1  - 5~n"),
    "hello world !" = iolist_to_str([[[$h],[$e],[$l],[$l],[$o],[$ ]], [$w,$o,$r], <<"ld !">>]),
    "hello world !" = iolist_to_str([[[$h],[$e],[<<"ll">>],[[[$o]]],[$ ]], $w, [$o,$r], <<"ld !">>]),

    %% check_range/2
    %%--------------------------------------------------------------------
    %% 
    io:format("test: check_range/1  - 1~n"),
    true = check_range(42, [23,52]),
    true = check_range(42, [52,23]),
    false = check_range(1, [2,3]),

    io:format("test: check_range/1  - 2.1~n"),
    1 = check_range(1, {[1,3],[-1,-3]}),
    io:format("test: check_range/1  - 2.2~n"),
    -2 = check_range(-2, {[1,3],[-1,-3]}),
    io:format("test: check_range/1  - 2.3~n"),
    autotest:fail(fun() -> check_range(0, {[1,3],[-1,-3]}) end),

    %% is_language_tag/1
    %%--------------------------------------------------------------------
    %%
    io:format("test: is_language_tag  - 1~n"),
    is_language_tag("f"),
    
    io:format("test: is_language_tag  - 2~n"),
    is_language_tag("fr"),

    io:format("test: is_language_tag  - 3~n"),
    is_language_tag("de-En-Bar"),

    %% to long sub part
    io:format("test: is_language_tag  - 4~n"),
    autotest:fail(fun() -> is_language_tag("abcdabcda") end),

    %% ilegal chars in first part of tag
    io:format("test: is_language_tag  - 5~n"),
    autotest:fail(fun() -> is_language_tag("abc42") end),

    %% empty string
    io:format("test: is_language_tag  - 6~n"),
    autotest:fail(fun() -> is_language_tag("") end),

    %% legal tag with numbers
    io:format("test: is_language_tag  - 9~n"),
    is_language_tag("de-En11-Bar22-24"),

    %% is_language_range/1
    %%--------------------------------------------------------------------
    %%
    io:format("test: is_language_range  - 1~n"),
    is_language_range("f"),
    
    io:format("test: is_language_range  - 2~n"),
    is_language_range("fr"),

    io:format("test: is_language_range  - 3~n"),
    is_language_range("de-En-Bar"),

    %% to long sub part
    io:format("test: is_language_range  - 4~n"),
    autotest:fail(fun() -> is_language_range("abcdabcda") end),

    %% ilegal chars in first part of range
    io:format("test: is_language_range  - 5~n"),
    autotest:fail(fun() -> is_language_range("abc42") end),

    %% empty string
    io:format("test: is_language_range  - 6~n"),
    autotest:fail(fun() -> is_language_range("") end),

    %% legal range with numbers
    io:format("test: is_language_range  - 9~n"),
    is_language_range("de-En11-Bar22-24"),

    %% empty string
    io:format("test: is_language_range  - 10~n"),
    is_language_range("*"),


    ok.