-module(ertorrent_file_srv).

-behaviour(gen_server).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {workers=[]}).

-define(FILE_SUP, ertorrent_file_sup).

pread(From, File, Offset) ->
    gen_server:cast(?MODULE, {pread, {self(), Worker}, File, Offset}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:stop(?MODULE).

init([]) ->
    ok = application:start(sasl),
    ok = application:start(os_mon),

    Mount_list = disksup:get_disk_data(),

    {ok, #state{}}.

terminate(_Reason, _State) ->
    ok = application:stop(os_mon),
    ok = application:stop(sasl),
    ok.

handle_call(terminate, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({pread, From, Info_hash, File, Offset}, State) ->
    case lists:keyfind(Info_hash, 2) of
        {Uid, Info_hash} ->
            Worker = Uid,
            New_workers = State#state.workers;
        false ->
            Uid = utils:unique_id(),
            Worker = supervisor:start_child(?FILE_SUP, [Uid, Info_hash]),
            New_workers = State#state{workers=[Worker | State#state.workers]}
    end,

    Worker ! {file_s_pread_req, From, File, Offset},
    {noreply, State}.

handle_info({file_w_pread_resp, From, File, Offset, Data}, State) ->
    {noreply, State};

code_change(_OldVsn, State, Extra) ->
    {ok, State}.
