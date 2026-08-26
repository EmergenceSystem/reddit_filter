%%%-------------------------------------------------------------------
%%% @doc Reddit search agent using public RSS/Atom feeds.
%%%
%%% The Reddit JSON API now returns 403/429 for unauthenticated clients,
%%% but the per-subreddit Atom feeds (/r/<sub>/<listing>.rss) still serve
%%% without OAuth. This agent fetches those feeds for a set of configured
%%% subreddits and keyword-filters the entries.
%%%
%%% Global /search.rss is rate-limited (429) and therefore not used;
%%% coverage comes from the subreddit listings instead.
%%%
%%% reddit_config.json (optional, read from CWD):
%%%   { "subreddits": ["rust","erlang"], "listing": "hot" }
%%%   listing can be: hot | new | top | rising
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(reddit_filter_app).

-export([handle/2, base_capabilities/0]).

-define(FEED_TTL, 120).  %% seconds
-define(UA, "Mozilla/5.0 (X11; Linux aarch64; rv:128.0) Gecko/20100101 Firefox/128.0").
-define(DEFAULT_SUBS, [<<"programming">>, <<"rust">>, <<"erlang">>,
                       <<"linux">>, <<"technology">>, <<"science">>,
                       <<"worldnews">>, <<"news">>]).

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"reddit">>, <<"community">>,
                                      <<"news">>, <<"programming">>].

handle(Body, Memory) when is_binary(Body) ->
    {Value, Timeout} = extract_params(Body),
    Config     = read_config(),
    Subreddits = case maps:get(<<"subreddits">>, Config, []) of
                     []   -> ?DEFAULT_SUBS;
                     Subs -> Subs
                 end,
    Listing    = binary_to_list(maps:get(<<"listing">>, Config, <<"hot">>)),
    LQuery     = string:lowercase(Value),
    Feeds0     = case Memory of M when is_map(M) -> maps:get(feeds, M, #{}); _ -> #{} end,
    Feeds1     = refresh_feeds(Subreddits, Listing, Timeout, Feeds0),
    Results    = lists:flatmap(fun(Sub) ->
                     case maps:get({Sub, Listing}, Feeds1, undefined) of
                         {_Ts, Xml} ->
                             lists:filtermap(
                               fun(E) -> match_entry(E, Sub, LQuery) end,
                               parse_entries(Xml));
                         _ -> []
                     end
                 end, Subreddits),
    Mem1 = case Memory of MM when is_map(MM) -> MM; _ -> #{} end,
    {Results, Mem1#{feeds => Feeds1}};
handle(_Body, Memory) ->
    {[], Memory}.

%% TTL cache: fetch only subreddits whose cached feed is missing or older
%% than ?FEED_TTL seconds. Stale fetches run in parallel; fresh ones are
%% reused from Memory. This keeps request volume low enough to avoid
%% Reddit rate-limiting (HTTP 429).
refresh_feeds(Subreddits, Listing, Timeout, Feeds0) ->
    Now  = erlang:system_time(second),
    Stale = [Sub || Sub <- Subreddits,
                    is_stale(maps:get({Sub, Listing}, Feeds0, undefined), Now)],
    Parent = self(),
    Pids = [spawn(fun() ->
                Parent ! {feed, self(), Sub, fetch(feed_url(Sub, Listing), Timeout)}
            end) || Sub <- Stale],
    DeadlineMs = erlang:system_time(millisecond) + Timeout * 1000,
    lists:foldl(fun(_, Acc) ->
        Remaining = max(0, DeadlineMs - erlang:system_time(millisecond)),
        receive
            {feed, _Pid, Sub, {ok, Xml}} ->
                Acc#{{Sub, Listing} => {Now, Xml}};
            {feed, _Pid, _Sub, _Err} ->
                Acc
        after Remaining -> Acc
        end
    end, Feeds0, Pids).

is_stale(undefined, _Now) -> true;
is_stale({Ts, _Xml}, Now) -> (Now - Ts) > ?FEED_TTL;
is_stale(_, _)            -> true.

feed_url(Sub, Listing) ->
    lists:concat(["https://www.reddit.com/r/", binary_to_list(Sub), "/",
                  Listing, ".rss?limit=50"]).

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

read_config() ->
    case file:read_file("reddit_config.json") of
        {ok, Bin} ->
            try json:decode(Bin) of
                Map when is_map(Map) -> Map;
                _                   -> #{}
            catch _:_ -> #{} end;
        _ -> #{}
    end.

parse_entries(Xml) ->
    case binary:split(Xml, <<"<entry>">>, [global]) of
        [_Head | Rest] -> [entry_block(P) || P <- Rest];
        _              -> []
    end.

entry_block(P) ->
    Block = case binary:split(P, <<"</entry>">>) of
                [B | _] -> B;
                _       -> P
            end,
    Title   = between(Block, <<"<title>">>, <<"</title>">>),
    Content = content_html(Block),
    Link    = link_href(Block),
    #{title => unescape(strip_cdata(Title)),
      link  => Link,
      body  => unescape(strip_cdata(Content))}.

between(Bin, A, B) ->
    case binary:split(Bin, A) of
        [_, Rest] ->
            case binary:split(Rest, B) of
                [Mid | _] -> Mid;
                _         -> <<>>
            end;
        _ -> <<>>
    end.

content_html(Block) ->
    case binary:split(Block, <<"<content">>) of
        [_, Rest] ->
            case binary:split(Rest, <<">">>) of
                [_Attrs, After] -> between2(After, <<"</content>">>);
                _               -> <<>>
            end;
        _ -> <<>>
    end.

between2(Bin, B) ->
    case binary:split(Bin, B) of
        [Mid | _] -> Mid;
        _         -> Bin
    end.

link_href(Block) ->
    case binary:split(Block, <<"<link href=\"">>) of
        [_, Rest] ->
            case binary:split(Rest, <<"\"">>) of
                [Url | _] -> unescape(Url);
                _         -> <<>>
            end;
        _ -> <<>>
    end.

strip_cdata(B) ->
    B1 = case binary:split(B, <<"<![CDATA[">>) of
             [_, R] -> R;
             _      -> B
         end,
    case binary:split(B1, <<"]]>">>) of
        [M, _] -> M;
        _      -> B1
    end.

unescape(B) ->
    L = [{<<"&amp;">>, <<"&">>}, {<<"&lt;">>, <<"<">>},
         {<<"&gt;">>, <<">">>}, {<<"&quot;">>, <<"\"">>},
         {<<"&#39;">>, <<"'">>}, {<<"&#x27;">>, <<"'">>}],
    lists:foldl(fun({A, R}, Acc) ->
        binary:replace(Acc, A, R, [global])
    end, B, L).

match_entry(#{title := Title, link := Link, body := Body}, Sub, LQuery) ->
    Hay = string:lowercase(binary_to_list(<<Sub/binary, " ", Title/binary, " ", Body/binary>>)),
    Matches = LQuery =:= "" orelse string:str(Hay, LQuery) > 0,
    case Matches andalso Link =/= <<>> of
        true ->
            Snippet = snippet(Body),
            Resume  = fmt("r/~ts - ~ts~ts", [Sub, Title, Snippet]),
            {true, #{<<"properties">> => #{
                <<"url">>    => Link,
                <<"title">>  => Title,
                <<"resume">> => Resume
            }}};
        false ->
            false
    end;
match_entry(_, _, _) -> false.

snippet(Body) ->
    NoTags  = re:replace(Body, <<"<[^>]*>">>, <<" ">>, [global, {return, binary}]),
    Clean   = re:replace(NoTags, <<"\s+">>, <<" ">>, [global, {return, binary}]),
    Trimmed = string:trim(Clean),
    case byte_size(Trimmed) of
        0 -> <<>>;
        _ ->
            Cut = binary:part(Trimmed, 0, min(160, byte_size(Trimmed))),
            <<" - ", Cut/binary>>
    end.

fetch(Url, TimeoutSecs) ->
    _ = application:ensure_all_started(ssl),
    _ = application:ensure_all_started(inets),
    Headers = [{"User-Agent", ?UA}, {"Accept", "application/atom+xml, text/xml"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, TimeoutSecs * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Code, _}, _, _}}   -> {error, {http, Code}};
        {error, R}                   -> {error, R}
    end.

fmt(F, Args) ->
    unicode:characters_to_binary(io_lib:format(F, Args)).
