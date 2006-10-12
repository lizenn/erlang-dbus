-module(connection).

-include("dbus.hrl").

%% -compile([export_all]).

-behaviour(gen_server).

%% api
-export([start_link/0, stop/0]).

-export([hex_to_list/1, calc_response/3, list_to_hexlist/1]).

%% gen_server callbacks
-export([init/1,
	 code_change/3,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2]).

-record(state, {
	  owner,
	  serial=0,
	  sock,
	  state,
	  buf= <<>>,
	  pending=[]
	 }).

-define(SERVER, ?MODULE).
-define(USER, "mikael").
-define(PORT, 1236).
-define(HOST, "localhost").

start_link() ->
    {ok, Pid} = gen_server:start_link({local, ?SERVER}, ?MODULE, [], []),
    {ok, Pid}.

stop() ->
    gen_server:cast(?SERVER, stop).


%%
%% gen_server callbacks
%%
init([]) ->
    User = ?USER,
    DbusHost = ?HOST,
    DbusPort = ?PORT,
    {ok, Sock} = gen_tcp:connect(DbusHost, DbusPort, [list, {packet, 0}]),
    ok = gen_tcp:send(Sock, <<0>>),
    ok = gen_tcp:send(Sock, ["AUTH DBUS_COOKIE_SHA1 ",
			     list_to_hexlist(User),
			     "\r\n"]),
    {ok, #state{sock=Sock}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(Request, _From, State) ->
    error_logger:error_msg("Unhandled call in ~p: ~p~n", [?MODULE, Request]),
    {reply, ok, State}.


handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in ~p: ~p~n", [?MODULE, Request]),
    {noreply, State}.


handle_info({tcp, Sock, Data}, #state{sock=Sock,state=up}=State) ->
    Buf = State#state.buf,
    {ok, State1} = handle_data(<<Buf/binary, Data/binary>>, State),
    {noreply, State1};

handle_info({tcp, Sock, "DATA " ++ Line}, #state{sock=Sock}=State) ->
    Data = hex_to_list(strip_eol(Line, [])),
    [Context, CookieId, ServerChallenge] = split(Data, $\ ),
    io:format("Data: ~p,~p,~p ~n", [Context, CookieId, ServerChallenge]),

    case read_cookie(CookieId) of
	error ->
	    {stop, {no_cookie, CookieId}, State};
	{ok, Cookie} ->
	    Challenge = calc_challenge(),
	    Response = calc_response(ServerChallenge, Challenge, Cookie),
	    ok = gen_tcp:send(Sock, ["DATA " ++ Response ++ "\r\n"]),

	    {noreply, State}
    end;

handle_info({tcp, Sock, "OK " ++ Line}, #state{sock=Sock}=State) ->
    Guid = strip_eol(Line, []),
    error_logger:info_msg("GUID ~p~n", [Guid]),
    ok = inet:setopts(Sock, [binary, {packet, raw}]),%, {recbuf, 8196}]),
    ok = gen_tcp:send(Sock, ["BEGIN\r\n"]),

    Owner = State#state.owner,
    Owner ! {ready, self()},

    {noreply, State#state{state=up}};

handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in ~p: ~p~n", [?MODULE, Info]),
    {noreply, State}.


terminate(_Reason, State) ->
    Sock = State#state.sock,
    gen_tcp:close(Sock),
    terminated.


handle_call(Header, Body, Tag, Pid, State) ->
%%     io:format("handle call ~p ~p~n", [Header, Body]),
    Sock = State#state.sock,
    Serial = State#state.serial + 1,

    {ok, Call} = call:start_link(self(), Tag, Pid),
    Pending = [{Serial, Call} | State#state.pending],

    {ok, Data} = marshaller:marshal_message(Header#header{serial=Serial}, Body),
    ok = gen_tcp:send(Sock, Data),
    
    {noreply, State#state{pending=Pending, serial=Serial}}.

handle_data(Data, State) ->
    {ok, Messages, Data1} = marshaller:unmarshal_data(Data),

    io:format("handle_data ~p ~p~n", [Messages, size(Data1)]),

%%     {ok, State1} = handle_messages(Messages, State#state{buf=Data1}),
    State1 = State,

    {ok, State1}.

calc_challenge() ->
    {MegaSecs, Secs, _MicroSecs} = now(),
    UnixTime = MegaSecs * 1000000 + Secs,
    Challenge = list_to_hexlist("Hello " ++ integer_to_list(UnixTime)),
    Challenge.

calc_response(ServerChallenge, Challenge, Cookie) ->
    A1 = ServerChallenge ++ ":" ++ Challenge ++ ":" ++ Cookie,
    io:format("A1: ~p~n", [A1]),
    Digest = crypto:sha(A1),
    DigestHex = list_to_hexlist(binary_to_list(Digest)),
    Response = list_to_hexlist(Challenge ++ " " ++ DigestHex),
    Response.

%% sha1_hash(Data) ->
%%     Context = crypto:sha_init(),
%%     Context1 = crypto:sha_update(Context, Data),
%%     Digest = crypto:sha_final(Context1),
%%     binary_Digest.
    

strip_eol([], Res) ->
    Res;
strip_eol([$\r|R], Res) ->
    strip_eol(R, Res);
strip_eol([$\n|R], Res) ->
    strip_eol(R, Res);
strip_eol([E|R], Res) ->
    strip_eol(R, Res ++ [E]).


list_to_hexlist(List) ->
    Fun = fun(E) ->
		  byte_to_hex(E)
	  end,
    
    lists:flatten(lists:map(Fun, List)).

byte_to_hex(E) ->
    High = E div 16,
    Low = E - High * 16,

    [nibble_to_hex(High), nibble_to_hex(Low)].

nibble_to_hex(Nibble) when Nibble >= 0, Nibble =< 9 ->
    Nibble + $0;
nibble_to_hex(Nibble) when Nibble >= 10, Nibble =< 15  ->
    Nibble - 10 + $a.
   

hex_to_list(Hex) ->
    hex_to_list(Hex, []).

hex_to_list([], List) ->
    List;
hex_to_list([H1, H2|R], List) ->
    List1 = List ++ [hex:from([H1, H2])],
    hex_to_list(R, List1).

read_cookie(CookieId) ->
    {ok, File} = file:open("/home/mikael/.dbus-keyrings/org_freedesktop_general", [read]),
    Result = read_cookie(File, CookieId),
    ok = file:close(File),
    Result.

read_cookie(Device, CookieId) ->
    case io:get_line(Device, "") of
	eof ->
	    error;
	Line ->
	    [CookieId1, _Time, Cookie] = split(strip_eol(Line, []), $\ ),
	    if
		CookieId == CookieId1 ->
		    {ok, Cookie};
		true ->
		    read_cookie(Device, CookieId)
	    end
    end.

split(List, Char) when is_list(List),
		       is_integer(Char) ->
    split(List, Char, "", []).

split([], _Char, Str, Res) ->
    Res ++ [Str];
split([Char|R], Char, Str, Res) ->
    split(R, Char, "", Res ++ [Str]);
split([C|R], Char, Str, Res) ->
    split(R, Char, Str ++ [C], Res).
