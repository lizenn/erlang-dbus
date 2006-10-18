%%%

-module(dberl.service_reg).

-import(error_logger).
-import(gen_server).
-import(gen_tcp).
-import(inet).
-import(io).
-import(lists).

-behaviour(gen_server).

-include("dbus.hrl").

%% api
-export([
	 start_link/0,
	 export_service/1
	]).

%% gen_server callbacks
-export([
	 init/1,
	 code_change/3,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2
	]).

-record(state, {
	  services=[]
	 }).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

export_service(ServiceName) ->
    gen_server:call(?SERVER, {export_service, ServiceName}).

%%
%% gen_server callbacks
%%
init([]) ->
    process_flag(trap_exit, true),
    bus_reg:set_service_reg(self()),
    {ok, #state{}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call({export_service, ServiceName}, _From, State) ->
    Services = State#state.services,
    case lists:keysearch(ServiceName, 1, Services) of
	{value, {_, Service}} ->
	    {reply, {ok, Service}, State};
	_ ->
	    io:format("~p: export_service name ~p~n", [?MODULE, ServiceName]),
	    {ok, Service} = service:start_link(ServiceName),
	    ok = bus_reg:export_service(Service, ServiceName),
	    Services1 = [{ServiceName, Service}|Services],
	    {reply, {ok, Service}, State#state{services=Services1}}
    end;

handle_call(Request, _From, State) ->
    error_logger:error_msg("Unhandled call in ~p: ~p~n", [?MODULE, Request]),
    {reply, ok, State}.


handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in ~p: ~p~n", [?MODULE, Request]),
    {noreply, State}.


handle_info({dbus_method_call, Header, Conn}, State) ->
    {_, ServiceNameVar} = message:header_fetch(?HEADER_DESTINATION, Header),
    ServiceName = list_to_atom(ServiceNameVar#variant.value),

%%     io:format("Handle call ~p ~p~n", [Header, ServiceName]),
    case lists:keysearch(ServiceName, 1, State#state.services) of
	{value, {ServiceName, Service}} ->
	    Service ! {dbus_method_call, Header, Conn};

	_ ->
	    ErrorName = "org.freedesktop.DBus.Error.ServiceUnknown",
	    ErrorText = "Erlang: Service not found.",
	    {ok, Reply} = message:build_error(Header, ErrorName, ErrorText),
	    io:format("Reply ~p~n", [Reply]),
	    ok = connection:reply(Conn, Reply)
    end,
    {noreply, State};

handle_info({new_bus, _Bus}, State) ->
    Fun = fun({ServiceName, Service}) ->
		  ok = bus_reg:export_service(Service, ServiceName)
	  end,
    lists:foreach(Fun, State#state.services),
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    Services = State#state.services,
    case lists:keysearch(Pid, 2, Services) of
	{value, _} ->
	    error_logger:info_msg("~p ~p Terminated ~p~n", [?MODULE, Pid, Reason]),
	    Services1 =
		lists:keydelete(Pid, 2, Services),
		    {noreply, State#state{services=Services1}};
	false ->
	    if
		Reason /= normal ->
		    {stop, Reason};
		true ->
		    {noreply, State}
	    end
    end;

handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in ~p: ~p~n", [?MODULE, Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    terminated.
