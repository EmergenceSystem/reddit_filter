-module(reddit_boot).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    {ok, Pid} = supervisor:start_link({local, reddit_boot_sup}, ?MODULE, []),
    _ = application:ensure_all_started(em_filter),
    _ = em_filter:start_agent(reddit_filter, reddit_filter_app,
          #{pop_port => 9550,
            query_port => 9551,
            capabilities => reddit_filter_app:base_capabilities(),
            pop_peers => [{"disco.roques.me", 443}],
            pop_advertise_host => <<"reddit.roques.me">>,
            pop_advertise_port => 443,
            pop_advertise_query_port => 443}),
    {ok, Pid}.

stop(_State) -> ok.

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 1, period => 5}, []}}.
