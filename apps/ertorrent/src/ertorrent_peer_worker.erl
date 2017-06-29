%%%-------------------------------------------------------------------
%%% @todo read up on edoc
%%% @doc torrent_gen, this is the interface to interact with the
%%% torrents.
%%% @end
%%% TODO:
%%%-------------------------------------------------------------------

-module(ertorrent_peer_worker).

-behaviour(gen_server).

-export([reset_rx_keep_alive/1,
         reset_tx_keep_alive/1,
         send_keep_alive/1,
         start_transmit/1]).

-export([start/5,
         start_link/5,
         stop/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-include("ertorrent_log.hrl").
-include("ertorrent_peer_tcp_message_ids.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(peer_state, {choked,
                     interested}).

-record(state, {cached_requests::list(),
                id, % peer_worker_id
                incoming_piece::binary(),
                incoming_piece_blocks::list(),
                incoming_piece_hash,
                incoming_piece_index,
                incoming_piece_downloaded_size,
                incoming_piece_total_size,
                % Piece queue is a list containing tuples with information for each piece
                % {index, hash, piece_size}
                incoming_piece_queue::list(),
                % Timer reference for when keep alive is expected from peer
                keep_alive_rx_ref,
                % Timer reference for when keep alive message should be sent
                keep_alive_tx_ref,
                % Piece queue is a list containing tuples with information for each piece
                % {index, hash, data}
                % outgoing_piece_queue will hold all the requested pieces until
                % they're completely transfered
                outgoing_piece_queue::list(),
                peer_bitfield,
                peer_id,
                peer_srv_pid,
                peer_state,
                received_handshake::boolean(),
                socket,
                state_incoming,
                state_outgoing,
                torrent_bitfield,
                torrent_info_hash,
                torrent_peer_id,
                torrent_pid}).

% 16KB seems to be an inofficial standard among most torrent client
% implementations. Link to the discussion:
% https://wiki.theory.org/Talk:BitTorrentSpecification#Messages:_request
-define(BLOCK_SIZE, 16000).
% Can't make the same assumption for external peers so this should be two
% minutes.
-define(KEEP_ALIVE_RX_TIMER, 120000).
% Should send keep-alive within two minutes. A little less than two minutes
% should be fine.
-define(KEEP_ALIVE_TX_TIMER, 100000).

-define(PEER_SRV, ertorrent_peer_srv).
-define(BITFIELD_UTILS, ertorrent_bitfield_utils).
-define(PEER_PROTOCOL, ertorrent_peer_tcp_protocol).

%%% Extended client API
start_transmit(ID) ->
    gen_server:cast(ID, transmit).

%%% Standard client API

% ID should be the address converted into an atom
start(ID, Info_hash, Peer_id, Socket, Torrent_pid) when is_atom(ID) ->
    gen_server:start({local, ID}, ?MODULE, [ID, Info_hash, Peer_id, Socket, Torrent_pid], []).

start_link(ID, Info_hash, Peer_id, Socket, Torrent_pid) when is_atom(ID) ->
    gen_server:start_link({local, ID}, ?MODULE, [ID, Info_hash, Peer_id, Socket, Torrent_pid], []).

stop(ID) ->
    io:format("stopping~n"),
    gen_server:cast({?MODULE, ID}, stop).

%%% Internal functions
reset_rx_keep_alive(Keep_alive_rx_ref) ->
    erlang:cancel(Keep_alive_rx_ref),

    erlang:send_after(?KEEP_ALIVE_RX_TIMER, self(), {keep_alive_rx_timeout}).

reset_tx_keep_alive(Keep_alive_tx_ref) ->
    erlang:cancel(Keep_alive_tx_ref),

    erlang:send_after(?KEEP_ALIVE_TX_TIMER, self(), {keep_alive_tx_timeout}).

send_keep_alive(Socket) ->
    TimerRef = erlang:send_after(?KEEP_ALIVE_TX_TIMER, self(), {keep_alive_internal_timeout}),

    case gen_tcp:send(Socket, <<0:32>>) of
        ok ->
            {ok, TimerRef};
        {error, Reason} ->
            erlang:cancel(TimerRef),
            {error, Reason}
    end.

blocks_to_piece(Blocks) ->
    Sorted_blocks = lists:keysort(1, Blocks),

    ?INFO("TODO This might work ..."),
    Blocks_tmp = lists:foldl(fun({_Idx, Data}, Total) ->
                                [Data| Total]
                             end, [], Sorted_blocks),

    Blocks_list = lists:reverse(Blocks_tmp),

    ?INFO("Converting list to binary"),
    list_to_binary(Blocks_list).

% Call peer_srv to forward a finished piece to the file_srv and prepare a state
% for the next piece.
complete_piece(State) ->
    Blocks = State#state.incoming_piece_blocks,
    Piece = blocks_to_piece(Blocks),

    State#state.peer_srv_pid ! {peer_worker_piece_ready,
                                State#state.torrent_pid,
                                State#state.incoming_piece_hash,
                                Piece},

    [{New_piece_index,
      New_piece_hash,
      New_piece_total_size}| New_piece_queue] = State#state.incoming_piece_queue,

    New_state = State#state{incoming_piece_blocks = [],
                            incoming_piece_downloaded_size = 0,
                            incoming_piece_index = New_piece_index,
                            incoming_piece_queue = New_piece_queue,
                            incoming_piece_total_size = New_piece_total_size,
                            incoming_piece_hash = New_piece_hash},

    {ok, New_state}.

%%% Callback module
init([ID, Info_hash, Peer_id, Socket, Torrent_pid]) when is_atom(ID) ->
    {ok, #state{id=ID,
                peer_id=Peer_id, % TODO Should this be retreived from settings_srv?
                peer_state=#peer_state{choked=true,
                                       interested=true},
                socket=Socket,
                torrent_info_hash=Info_hash,
                torrent_pid=Torrent_pid}}.

terminate(Reason, State) ->
    ?INFO("peer worker terminating: " ++ Reason),

    erlang:cancel_timer(State#state.keep_alive_rx_ref),
    erlang:cancel_timer(State#state.keep_alive_tx_ref),

    ok = gen_tcp:close(State#state.socket),

    ?PEER_SRV ! {peer_w_terminate,
                 State#state.id,
                 State#state.incoming_piece_hash},

    ok.

%% Synchronous
handle_call(_Req, _From, State) ->
    {noreply, State}.

%% Asynchronous
handle_cast({activate}, State) ->
    Info_hash = State#state.torrent_info_hash,
    Peer_id = State#state.peer_id,

    case gen_tcp:send(State#state.socket,
                      <<19:32, "BitTorrent protocol":152, 0:64,
                        Info_hash:160,
                        Peer_id:160>>) of
        ok ->
            % This is automatically canceled if the process terminates
            Keep_alive_tx_ref = erlang:send_after(?KEEP_ALIVE_TX_TIMER,
                                                  self(),
                                                  {keep_alive_tx_timeout}),

            Keep_alive_rx_ref = erlang:send_after(?KEEP_ALIVE_RX_TIMER,
                                                  self(),
                                                  {keep_alive_rx_timeout}),

            {noreply, State#state{keep_alive_rx_ref=Keep_alive_rx_ref, keep_alive_tx_ref=Keep_alive_tx_ref}};
        {error, Reason} ->
            {stop, {error_handshake, Reason}}
    end;
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(Request, State) ->
    ?WARNING("unhandled request: " ++ Request),
    {noreply, State}.

%% Timeout for when a keep alive message was expected from the peer
handle_info({keep_alive_rx_timeout}, State) ->
    {stop, peer_worker_timed_out, State};

%% Time to send another keep alive before the peer mark us as inactive
handle_info({keep_alive_tx_timeout}, State) ->
    case send_keep_alive(State#state.socket) of
        {ok, Timer_ref} ->
            New_state = State#state{keep_alive_tx_ref=Timer_ref},
            {noreply, New_state};
        {error, Reason} ->
            {stop, Reason, State}
    end;

%% Async. response when requested a new piece to transmit. Answer the cached
%% request that triggered a piece to be retrieved from disk.
handle_info({peer_srv_tx_piece, Index, Hash, Data}, State) ->
    Outgoing_pieces = [{Index, Hash, Data}| State#state.outgoing_piece_queue],

    % Compile a list of pending requests that match the received piece
    Pending_requests = lists:filter(
                           fun({request, R_index, _R_begin, _R_length}) ->
                               case Index == R_index of
                                   true -> true;
                                   false -> false
                               end
                           end, State#state.cached_requests
                       ),

    % Respond to the pending requests and compile a list with the served
    % requests
    Served_requests = lists:foldl(
                          fun(Request, Acc) ->
                              {request, R_index, R_begin, R_length} = Request,

                              % TODO figure out how to handle the last block of a piece
                              <<_B_begin:R_begin, Block:R_length, _Rest/binary>> = Data,

                              Msg = ?PEER_PROTOCOL:msg_piece(R_length, R_index, R_begin, Block),

                              case gen_tcp:send(State#state.socket, Msg) of
                                  ok ->
                                      [Request| Acc];
                                  {error, Reason} ->
                                      ?WARNING("failed to serve a pending request: " ++ Reason),
                                      Acc
                              end
                          end, [], Pending_requests
                      ),

    % Filter out the served requests
    Remaining_requests = lists:filter(
                            fun(Request) ->
                                case Request of
                                    {request, _R_index, _R_begin, _R_length} ->
                                        false;
                                    _ ->
                                        true
                                end
                            end, Served_requests
                         ),

    New_state = State#state{cached_requests = Remaining_requests,
                            outgoing_piece_queue = Outgoing_pieces},

    {noreply, New_state};

%% Messages from gen_tcp
% TODO:
% - Implement the missing fast extension
handle_info({tcp, _S, <<>>}, State) ->
    New_keep_alive_rx_ref = reset_rx_keep_alive(State#state.keep_alive_rx_ref),

    New_state = State#state{keep_alive_rx_ref=New_keep_alive_rx_ref},

    {noreply, New_state};
handle_info({tcp, _S, <<?HAVE, Piece_num:32/big-integer>>}, State) ->
    New_bitfield = ?BITFIELD_UTILS:set_bit(Piece_num, 1, State#state.peer_bitfield),
    New_state = State#state{peer_bitfield = New_bitfield},

    State#state.peer_srv_pid ! {peer_w_bitfield_update, New_bitfield},
    % TODO if we're sending a piece that is announced in a HAVE message, should
    % we cancel the tranmission or ignore it and wait for a CANCEL message?

    {noreply, New_state};
handle_info({tcp, _S, <<?REQUEST, Index:32/big, Begin:32/big, Length:32/big>>}, State) ->
    case lists:keyfind(Index, 1, State#state.outgoing_piece_queue) of
        {Index, _Hash, Data} ->
            <<Begin, Block:Length, _Rest/binary>> = Data,

            Msg = ?PEER_PROTOCOL:msg_piece(Length, Index, Begin, Block),

            % TODO figure out a smart way to detect when we can clear out
            % cached pieces
            case gen_tcp:send(State#state.socket, Msg) of
                {error, Reason} ->
                    ?WARNING("failed to send a REQUEST response: " ++ Reason)
            end,

            New_state = State;
        false ->
            % If the requested piece ain't cached, send a request to read the
            % piece form disk and meanwhile cache the request.
            Cached_requests = [{request, Index, Begin, Length}|
                               State#state.cached_requests],

            State#state.peer_srv_pid ! {peer_w_piece_request, self(), Index},

            New_state = State#state{cached_requests=Cached_requests}
    end,

    {noreply, New_state};
handle_info({tcp, _S, <<?PIECE, Index:32/big-integer,
                                        Begin:32/big-integer, Data/binary>>},
            State) ->
    ?INFO("piece index: " ++ Index ++ " begin: " ++ Begin),
    case Index == State#state.incoming_piece_index of
        true ->
            Size = State#state.incoming_piece_downloaded_size + binary:referenced_byte_size(Data),

            case Size of
                Size when Size < State#state.incoming_piece_total_size ->
                    New_blocks = [{Begin, Data}| State#state.incoming_piece_blocks],
                    New_size = Size,

                    New_state = State#state{incoming_piece_blocks = New_blocks,
                                            incoming_piece_downloaded_size = New_size};
                Size when Size == State#state.incoming_piece_total_size ->
                    {ok, New_state} = complete_piece(State);
                Size when Size > State#state.incoming_piece_total_size ->
                    ?ERROR("Size of the piece is larger than it is supposed to. Discarding blocks"),
                    New_state = State
            end;
        false ->
            ?WARNING("Received blocks belonging to another piece"),
            New_state = State
    end,

    {noreply, New_state};
handle_info({tcp, _S, <<?CHOKE>>}, State) ->
    State#state.peer_srv_pid ! {peer_worker_choke},
    {noreply, State};
handle_info({tcp, _S, <<?UNCHOKE>>}, State) ->
    {unchoke},
    {noreply, State};
handle_info({tcp, _S, <<?INTERESTED>>}, State) ->
    {interested},
    {noreply, State};
handle_info({tcp, _S, <<?NOT_INTERESTED>>}, State) ->
    {not_interested},
    {noreply, State};
handle_info({tcp, _S, <<?CANCEL, Index:32/big, Begin:32/big,
                                        Len:32/big>>}, State) ->
    {cancel, Index, Begin, Len},
    {noreply, State};
handle_info({tcp, _S, <<19:32, "BitTorrent protocol", 0:64, Info_hash:160,
                        _Peer_id:160>>}, State) ->
    % TODO add validation of Peer_id
    case string:equals(State#state.torrent_info_hash, Info_hash) of
        true when State#state.received_handshake =:= false ->
            New_state = State#state{received_handshake=true},
            {noreply, New_state};
        true when State#state.received_handshake =:= true ->
            ?INFO("received multiple handshakes for peer: " ++ State#state.id),
            {noreply, State};
        false ->
            ?WARNING("received invalid info hash in handshake for peer: " ++ State#state.id),
            {stop, "invalid handshake", State}
    end;

handle_info({tcp, _S, <<?BITFIELD, Bitfield/binary>>}, State) ->
    ?INFO("peer[" ++ State#state.id ++ "] received bitfield " ++ Bitfield),
    {noreply, State};
handle_info({tcp, _S, <<?PORT, _Port:16/big>>}, State) ->
    {noreply, State};
handle_info({tcp, _S, Data}, State) ->
    ?WARNING("unhandled peer[" ++ State#state.id ++"], message: " ++ Data),
    {stop, peer_unhandled_message, State};
handle_info({tcp_closed, _S}, State) ->
    {stop, peer_connection_closed, State};
handle_info(Message, State) ->
    ?WARNING("unhandled message: " ++ Message),
    {noreply, State}.

%% Messages from the torrent worker
% handle_info({torrent_worker_choke}, State) ->
%     {ok, Msg} = ?PEER_PROTOCOL:msg_choke();
% handle_info({torrent_worker_unchoke}, State) ->
%     {ok, Msg} = ?PEER_PROTOCOL:msg_unchoke().

