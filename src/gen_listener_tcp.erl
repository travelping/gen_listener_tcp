-module(gen_listener_tcp).
-behaviour(gen_server).

-export([behaviour_info/1]).

-export([
	 start/3,
	 start/4,
	 start_link/3,
	 start_link/4,
	 call/2,
	 call/3,
	 multicall/2,
	 multicall/3,
	 multicall/4,
	 cast/2,
	 abcast/2,
	 abcast/3,
	 reply/2
	]).

-export([
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

-export([
	 sockname/1
	]).

-record(listener_state, {
	  verbose = false :: boolean(),
	  socket,
	  acceptor,
	  mod,
	  mod_state
	 }).


behaviour_info(callbacks) ->
    [
     {init, 1},
     {handle_accept, 2},
     {handle_call, 3},
     {handle_cast, 2},
     {handle_info, 2},
     {terminate, 2},
     {code_change, 3}
    ].


start_link(Name, Module, InitArgs, Options) ->
    gen_server:start_link(Name, ?MODULE, [{'__gen_listener_tcp_mod', Module} | InitArgs], Options).

start_link(Module, InitArgs, Options) ->
    gen_server:start_link(?MODULE, [{'__gen_listener_tcp_mod', Module} | InitArgs], Options).

start(Name, Module, InitArgs, Options) ->
    gen_server:start(Name, ?MODULE, [{'__gen_listener_tcp_mod', Module} | InitArgs], Options).

start(Module, InitArgs, Options) ->
    gen_server:start(?MODULE, [{'__gen_listener_tcp_mod', Module} | InitArgs], Options).

call(ServerRef, Request) ->
    gen_server:call(ServerRef, Request).

call(ServerRef, Request, Timeout) ->
    gen_server:call(ServerRef, Request, Timeout).

multicall(Name, Request) ->
    gen_server:multi_call(Name, Request).

multicall(Nodes, Name, Request) ->
    gen_server:multi_call(Nodes, Name, Request).

multicall(Nodes, Name, Request, Timeout) ->
    gen_server:multi_call(Nodes, Name, Request, Timeout).

cast(ServerRef, Request) ->
    gen_server:cast(ServerRef, Request).

abcast(Name, Request) ->
    gen_server:abcast(Name, Request).

abcast(Nodes, Name, Request) ->
    gen_server:abcast(Nodes, Name, Request).

reply(Client, Reply) ->
    gen_server:reply(Client, Reply).

sockname(ServerRef) ->
    call(ServerRef, '__gen_listener_tcp_mod_sockname').

% gen_server callbacks

init([{'__gen_listener_tcp_mod', Module} | InitArgs]) ->
    process_flag(trap_exit, true),

    case Module:init(InitArgs) of
        {ok, {Port, Options}, ModState} ->
            Verbose = proplists:get_bool(verbose, Options),
            Options0 = proplists:delete(verbose, Options),

            {ok, ListenSocket} = gen_tcp:listen(Port, Options0),

            info_report(Verbose, [listening_started, {port, Port}, {lsock, ListenSocket} | Options0]), 

            {ok, create_acceptor(ListenSocket, Module, ModState, Verbose)};
        ignore ->
            ignore;
        {stop, Reason} ->
            {stop, Reason};
        Other ->
            {stop, Other}
    end.


handle_call('__gen_listener_tcp_mod_sockname', _From, #listener_state{socket=Socket}=St) ->
    Reply = inet:sockname(Socket),
    {reply, Reply, St};

handle_call(Request, From, #listener_state{mod=Module, mod_state=ModState}=St) ->
    case Module:handle_call(Request, From, ModState) of 
        {reply, Reply, NewModState} ->
            {reply, Reply, St#listener_state{mod_state=NewModState}};
        {reply, Reply, NewModState, hibernate} ->
            {reply, Reply, St#listener_state{mod_state=NewModState}, hibernate};
        {reply, Reply, NewModState, Timeout} ->
            {reply, Reply, St#listener_state{mod_state=NewModState}, Timeout};
        {noreply, NewModState} ->
            {noreply, St#listener_state{mod_state=NewModState}};
        {noreply, NewModState, hibernate} ->
            {noreply, St#listener_state{mod_state=NewModState}, hibernate};
        {noreply, NewModState, Timeout} ->
            {noreply, St#listener_state{mod_state=NewModState}, Timeout};
        {stop, Reason, NewModState} ->
            {stop, Reason, St#listener_state{mod_state=NewModState}};
        {stop, Reason, Reply, NewModState} ->
            {stop, Reason, Reply, St#listener_state{mod_state=NewModState}}
    end.

handle_cast(Request, #listener_state{mod=Module, mod_state=ModState}=St) ->
    case Module:handle_cast(Request, ModState) of
        {noreply, NewModState} ->
            {noreply, St#listener_state{mod_state=NewModState}};
        {noreply, NewModState, hibernate} ->
            {noreply, St#listener_state{mod_state=NewModState}, hibernate};
        {noreply, NewModState, Timeout} ->
            {noreply, St#listener_state{mod_state=NewModState}, Timeout};
        {stop, Reason, NewModState} ->
            {stop, Reason, St#listener_state{mod_state=NewModState}}
    end.


handle_info({inet_async, LSock, ARef, {ok, ClientSock}}, #listener_state{verbose = Verbose, socket=LSock, acceptor=ARef, mod=Module, mod_state=ModState}=St) ->
    info_report(Verbose, [new_connection, {csock, ClientSock}, {lsock, LSock}, {async_ref, ARef}]),
    patch_client_socket(ClientSock, LSock),

    info_report(Verbose, [handling_accept, {module, Module}, {module_state, ModState}]),

    try
        case Module:handle_accept(ClientSock, ModState) of
            {noreply, NewModState} ->
                {noreply, create_acceptor(St#listener_state{mod_state=NewModState})};
            {noreply, NewModState, hibernate} ->
                {noreply, create_acceptor(St#listener_state{mod_state=NewModState}), hibernate};
            {noreply, NewModState, Timeout} ->
                {noreply, create_acceptor(St#listener_state{mod_state=NewModState}), Timeout};
            {stop, Reason, NewModState} ->
                {stop, Reason, create_acceptor(St#listener_state{mod_state=NewModState})}
        end
    catch
        Type:Exception ->
            error_report(Verbose, [gen_listener_tcp, {action, handle_accept}, {type, Type}, {exception, Exception}]),
            gen_tcp:close(ClientSock),
            {noreply, St}
    end;

handle_info({inet_async, LSock, ARef, Error}, #listener_state{verbose = Verbose, socket=LSock, acceptor=ARef}=ListenerState) ->
    error_report(Verbose, [acceptor_error, {reason, Error}, {lsock, LSock}, {async_ref, ARef}]),
    {stop, Error, ListenerState};

handle_info(Info, #listener_state{mod=Module, mod_state=ModState}=St) ->
    case Module:handle_info(Info, ModState) of
        {noreply, NewModState} ->
            {noreply, St#listener_state{mod_state=NewModState}};
        {noreply, NewModState, hibernate} ->
            {noreply, St#listener_state{mod_state=NewModState}, hibernate};
        {noreply, NewModState, Timeout} ->
            {noreply, St#listener_state{mod_state=NewModState}, Timeout};
        {stop, Reason, NewModState} ->
            {stop, Reason, St#listener_state{mod_state=NewModState}}
    end.

terminate(Reason, #listener_state{verbose = Verbose, mod=Module, mod_state=ModState}=St) ->
    info_report(Verbose, [listener_terminating, {reason, Reason}]),
    gen_tcp:close(St#listener_state.socket),
    Module:terminate(Reason, ModState).

code_change(OldVsn, #listener_state{mod=Module, mod_state=ModState}=St, Extra) ->
    {ok, NewModState} = Module:code_change(OldVsn, ModState, Extra),
    {ok, St#listener_state{mod_state=NewModState}}.


% prim_inet imports
patch_client_socket(CSock, LSock) when is_port(CSock), is_port(LSock) ->
    {ok, Module} = inet_db:lookup_socket(LSock),
    true = inet_db:register_socket(CSock, Module),

    {ok, Opts} = prim_inet:getopts(LSock, [active, nodelay, keepalive, delay_send, priority, tos]),
    ok = prim_inet:setopts(CSock, Opts),
    ok.

create_acceptor(St) when is_record(St, listener_state) ->
    create_acceptor(St#listener_state.socket, St#listener_state.mod, St#listener_state.mod_state, St#listener_state.verbose).

create_acceptor(ListenSocket, Module, ModState, Verbose) when is_port(ListenSocket) ->
    {ok, Ref} = prim_inet:async_accept(ListenSocket, -1), 

    info_report(Verbose, waiting_for_connection),
    #listener_state{verbose = Verbose, socket=ListenSocket, acceptor=Ref, mod=Module, mod_state=ModState}.

info_report(_Verbose = false, _Report) ->
	ok;
info_report(Verbose, Report)
  when Verbose == true; Verbose == info ->
	error_logger:info_report(Report).

error_report(_Verbose = false, _Report) ->
	ok;
error_report(Verbose, Report)
  when Verbose == true; Verbose == error ->
	error_logger:error_report(Report).
