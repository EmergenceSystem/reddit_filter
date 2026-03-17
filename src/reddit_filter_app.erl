%%%-------------------------------------------------------------------
%%% @doc Reddit search agent using the public JSON API.
%%%
%%% Two search modes running in parallel:
%%%
%%%   Subreddit listing — fetches hot/new posts from configured
%%%                       subreddits and filters by keyword.
%%%
%%%   Reddit search     — uses reddit.com/search.json to search
%%%                       across all of Reddit or restricted to
%%%                       configured subreddits.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%   Topic-specific filters extend reddit_filter_app:base_capabilities():
%%%
%%% reddit_config.json format:
%%%   {
%%%     "subreddits": ["erlang", "programming", "linux"],
%%%     "search_reddit": true,
%%%     "listing": "hot"
%%%   }
%%%
%%% listing can be: "hot" | "new" | "top" | "rising"
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(reddit_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(USER_AGENT, "EmergenceSystem/1.0 (em_filter reddit agent)").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"reddit">>, <<"community">>,
                                      <<"news">>, <<"programming">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(reddit_filter, ?MODULE, #{
        capabilities => base_capabilities()
    }).

stop(_State) ->
    em_filter:stop_agent(reddit_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Aggregation — subreddit listing + global search in parallel
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Config     = read_config(),
    Subreddits = maps:get(<<"subreddits">>,    Config, []),
    DoSearch   = maps:get(<<"search_reddit">>, Config, true),
    Listing    = binary_to_list(maps:get(<<"listing">>, Config, <<"hot">>)),
    Parent     = self(),

    SubPids = [spawn(fun() ->
        Parent ! {sub_result, Sub,
                  search_subreddit(Sub, Listing, Value, Timeout)}
    end) || Sub <- Subreddits],

    SearchPid = case DoSearch andalso Value =/= "" of
        true ->
            Pid = spawn(fun() ->
                Parent ! {search_result,
                          search_global(Value, Subreddits, Timeout)}
            end),
            [Pid];
        false -> []
    end,

    DeadlineMs = erlang:system_time(millisecond) + Timeout * 1000,

    SubResults = lists:flatmap(fun(_) ->
        Remaining = max(0, DeadlineMs - erlang:system_time(millisecond)),
        receive
            {sub_result, _Sub, Results} -> Results
        after Remaining -> []
        end
    end, SubPids),

    SearchResults = case SearchPid of
        [] -> [];
        _  ->
            Remaining = max(0, DeadlineMs - erlang:system_time(millisecond)),
            receive
                {search_result, Results} -> Results
            after Remaining -> []
            end
    end,

    SubResults ++ SearchResults.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

read_config() ->
    case file:read_file("reddit_config.json") of
        {ok, Bin} ->
            try json:decode(Bin) of
                Map when is_map(Map) -> Map;
                _                   -> #{}
            catch _:_ -> #{} end;
        _ -> #{}
    end.

%%====================================================================
%% Subreddit listing search
%%====================================================================

search_subreddit(Sub, Listing, Query, TimeoutSecs) ->
    SubStr = binary_to_list(Sub),
    Url    = lists:concat(["https://www.reddit.com/r/", SubStr, "/",
                            Listing, ".json?limit=50"]),
    case fetch_json(Url, TimeoutSecs) of
        {ok, #{<<"data">> := #{<<"children">> := Posts}}} ->
            LQuery = string:lowercase(Query),
            lists:filtermap(fun(P) -> process_post(P, LQuery) end, Posts);
        _ ->
            []
    end.

%%====================================================================
%% Global Reddit search
%%====================================================================

search_global(Query, Subreddits, TimeoutSecs) ->
    Restrict = case Subreddits of
        [] -> "";
        _  ->
            Subs = string:join([binary_to_list(S) || S <- Subreddits], "+"),
            "&restrict_sr=true&sr_name=" ++ Subs
    end,
    Url = lists:concat(["https://www.reddit.com/search.json?q=",
                         uri_string:quote(Query),
                         "&sort=relevance&limit=25",
                         Restrict]),
    case fetch_json(Url, TimeoutSecs) of
        {ok, #{<<"data">> := #{<<"children">> := Posts}}} ->
            lists:filtermap(
                fun(P) -> process_post(P, string:lowercase(Query)) end,
                Posts);
        _ ->
            []
    end.

%%====================================================================
%% Post processing
%%====================================================================

process_post(#{<<"data">> := Post}, Query) ->
    Title     = to_str(maps:get(<<"title">>,    Post, <<>>)),
    Selftext  = to_str(maps:get(<<"selftext">>, Post, <<>>)),
    Permalink = maps:get(<<"permalink">>,       Post, <<>>),
    Score     = maps:get(<<"score">>,           Post, 0),
    Sub       = maps:get(<<"subreddit">>,       Post, <<>>),
    Comments  = maps:get(<<"num_comments">>,    Post, 0),
    Url       = <<"https://www.reddit.com", Permalink/binary>>,
    Matches   =
        string:str(string:lowercase(Title),    Query) > 0 orelse
        string:str(string:lowercase(Selftext), Query) > 0,
    case Matches of
        true ->
            Resume = fmt("r/~ts — ~ts [~p pts | ~p comments]",
                         [Sub, Title, Score, Comments]),
            {true, #{<<"properties">> => #{
                <<"url">>    => Url,
                <<"title">>  => unicode:characters_to_binary(Title),
                <<"resume">> => Resume
            }}};
        false ->
            false
    end;
process_post(_, _) -> false.

%%====================================================================
%% HTTP helper
%%====================================================================

fetch_json(Url, TimeoutSecs) ->
    Headers = [{"User-Agent", ?USER_AGENT}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, TimeoutSecs * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            try {ok, json:decode(Body)}
            catch _:_ -> {error, invalid_json} end;
        {ok, {{_, Code, _}, _, _}} -> {error, {http, Code}};
        {error, R}                 -> {error, R}
    end.

%%====================================================================
%% Internal helpers
%%====================================================================

fmt(F, Args) ->
    unicode:characters_to_binary(io_lib:format(F, Args)).

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(_)                   -> "".
