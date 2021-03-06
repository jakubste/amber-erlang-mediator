-module(router).

-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").

-include("drivermsg_pb.hrl").
-include("routing.hrl").

-record(state, {mid, conf}).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).
-export([start_node/2, receive_msg/2]).

-export([send_msg/2, pack_msg/2, unpack_msg/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%        BEHAVIOUR DEFINITION        %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Obsługa przychodzącej wiadomości.
%% Parametry: {Module, MID}, header, msg.
%% Poniższa składnia dostępna od Erl/OTP R15.
-callback receive_msg(tuple(), #routing_msg{}) ->
  'ok'.

%% Uruchomienie węzła.
%% Parametry: MID, Conf
%% Funkcja powinna wywołać register_routing.
-callback start_node(tuple(), [any()]) ->
  {'ok', pid()}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%        "ROUTER JEST WĘZŁEM"        %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_node(MID, Conf) ->
  io:format("Starting server~n"),
  error_logger:error_msg("Starting server~n"),
  gen_server:start_link({local, router}, ?MODULE, {MID, Conf}, []).

receive_msg(_MID, #routing_msg{}) -> %% TODO: wiadomość do routera??
  ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%         ROUTER DOSTARCZA API        %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Wysłanie wiadomości.
-spec send_msg({module(), tuple()}, #routing_msg{}) ->
  'ok'.

send_msg(Sender, #routing_msg{hdr = Hdr, msg = Msg}) ->
  gen_server:cast(router, {send_msg, Sender, Hdr, Msg}).


-spec pack_msg(#driverhdr{}, binary()) ->
  binary().

pack_msg(Hdr, MsgB) ->
  HdrB = drivermsg_pb:encode_driverhdr(Hdr),
  HdrB_Len = byte_size(HdrB),
  MsgB_Len = byte_size(MsgB),
  <<HdrB_Len:2/big-unsigned-integer-unit:8, HdrB/binary,
  MsgB_Len:2/big-unsigned-integer-unit:8, MsgB/binary>>.


-spec unpack_msg(binary()) ->
  {#driverhdr{}, binary()}.

unpack_msg(<<HdrB_Len:2/big-unsigned-integer-unit:8, MsgRest/binary>>) ->
  <<HdrB:HdrB_Len/binary, MsgB_Len:2/big-unsigned-integer-unit:8, MsgB/binary>> = MsgRest,
  MsgB_Len = byte_size(MsgB),
  Hdr = drivermsg_pb:decode_driverhdr(HdrB),
  {Hdr, MsgB}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%       ROUTER JEST GEN_SERVEREM      %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({MID, Conf}) ->
  io:format("Initializing server~n"),
  error_logger:error_msg("Initializing server~n"),
  {ok, #state{mid = MID, conf = Conf}}.

handle_call(_, _, State) ->
  io:format("Handle-call in server~n"),
  error_logger:error_msg("Handle-call in server~n"),
  {noreply, State}.

handle_cast({send_msg, Sender, #driverhdr{devicetype = DevT, deviceid = DevI}, Msg}, State)
  when is_integer(DevT), is_integer(DevI) ->
  io:format("Handle-cast in server~n"),

  % od klienta do drivera %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  Q1 = fun() ->
    mnesia:select(routing_node, ets:fun2ms(fun(#routing_node{id = Id, mod_id = MID})
      when
      MID =:= Sender -> Id
    end))
  end,

  %% receiver_DevTI → receiver_ModID

  Q2 = fun() ->
    mnesia:select(routing_node, ets:fun2ms(fun(#routing_node{mod_id = MID, dev_ti = DTI})
      when
      DTI =:= {DevT, DevI} -> MID
    end))
  end,

  SenderGID =
    case mnesia:transaction(Q1) of
      {atomic, [C_SenderGID]} ->
        C_SenderGID;

      {atomic, []} ->
        NRef = make_ref(),

        Q2b = fun(#routing_node{id = ID}, MID)
          when
          ID > MID -> ID;
          (_, MID) -> MID
        end,

        Q2c = fun() ->
          NewId = mnesia:foldl(Q2b, 0, routing_node) + 1,
          NewNode = #routing_node{id = NewId, mod_id = Sender, dev_ti = NRef, conf = []},
          mnesia:dirty_write(NewNode),
          NewId
        end,

        {atomic, N_SenderGID} = mnesia:transaction(Q2c),
        N_SenderGID
    end,

  case mnesia:transaction(Q2) of
    {atomic, [{RecMod, RecMID}]} ->
      RecMod:receive_msg(RecMID, #routing_msg{hdr = #driverhdr{clientids = [SenderGID]}, msg = Msg});

    {atomic, Res} ->
      error_logger:error_msg("Wiadomość od (klienta) ~p (#~p) do (sterownika) (~p,~p) nie może być dostarczona~n"
      "  Wynik z bazy: ~p~n", [Sender, SenderGID, DevT, DevI, Res])
  end,

  {noreply, State};

handle_cast({send_msg, _Sender, #driverhdr{clientids = []}, _Msg}, State) ->
  {noreply, State};

handle_cast({send_msg, Sender, #driverhdr{clientids = [C | Cs]} = Hdr, Msg}, State) ->

  % od drivera do klienta %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

  %% sender_ModID → sender_DevTI

  Q1 = fun() ->
    mnesia:select(routing_node, ets:fun2ms(fun(#routing_node{dev_ti = DTI, mod_id = MID})
      when
      MID =:= Sender -> DTI
    end))
  end,

  %% receiver_GID → receiver_ModID

  Q2 = fun() ->
    mnesia:select(routing_node, ets:fun2ms(fun(#routing_node{mod_id = MID, id = ID})
      when
      ID =:= C -> MID
    end))
  end,

  case {mnesia:transaction(Q1), mnesia:transaction(Q2)} of
    {{atomic, [{DevT, DevI}]}, {atomic, [{RecMod, RecMID}]}} ->
      RecMod:receive_msg(RecMID, #routing_msg{hdr = Hdr#driverhdr{clientids = [], devicetype = DevT, deviceid = DevI}, msg = Msg});

    {{atomic, ResQ1}, {atomic, ResQ2}} ->
      error_logger:error_msg("Wiadomość od (sterownika) ~p do (klienta) ~p nie może być dostarczona~n"
      "  Wynik z bazy (sterownik): ~p~n"
      "  Wynik z bazy (klient):    ~p~n", [Sender, C, ResQ1, ResQ2])
  end,

  handle_cast({send_msg, Sender, Hdr#driverhdr{clientids = Cs}, Msg}, State);

handle_cast(_, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  % TODO: send info to all nodes
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
