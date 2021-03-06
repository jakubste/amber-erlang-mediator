-module(driver_sup).

-behaviour(supervisor).

-include("config.hrl").

-export([start_link/1]).
-export([init/1]).

-ifdef(TEST).
-define(SETTINGS_FILE, "../priv/test_settings.config").
-else.
-define(SETTINGS_FILE, "priv/settings.config").
-endif.

-define(CHILD(Mod, Args), {{Mod, Args, make_ref()}, {Mod, start_node, Args}, transient, 5000, worker, [Mod]}).

-spec start_link([#supervised_driver{}]) ->
  {'ok', pid()} | 'ignore' | {'error', any()}.

start_link(Nodes) ->
  Children = lists:map(fun(#supervised_driver{mod_id = {Mod, MID}, conf = Conf}) ->
    ?CHILD(Mod, [MID, Conf])
  end, Nodes),

  supervisor:start_link({local, ?MODULE}, ?MODULE, Children).

init(Children) ->
  {ok, {{one_for_one, 2, 10}, Children}}.
