-module(http_announce).

-include("metainfo.hrl").
-include("announce_response.hrl").
-include("peer.hrl").

-export([do_announce/1]).

do_announce(Metainfo) ->
    #metainfo{announce=Announce_address,
              info_hash=Info_hash,
              info=Info} = Metainfo,
    #info{length=Length} = Info,
    Peer_id = string:concat("ET-0-0-1", string:chars($ , 12)),
    %Replacing reserved characters
    Peer_id_encoded = edoc_lib:escape_uri(Peer_id),
    %compact=1 is required by BEP 23:
    %http://www.bittorrent.org/beps/bep_0023.html
    Basic_request = basic_request(Announce_address,
                                  Info_hash,
                                  Peer_id_encoded,
                                  Length),
    {ok, Code, Basic_response} = send_request(Basic_request),
    erlang:display(Basic_request),
    if
        Code =:= 200 ->
            erlang:display("BASIC REQUEST"),
            {ok, Response} = parse_response(Basic_response);
        Code =:= 400 ->
            erlang:display("COMPACT REQUEST"),
            Compact_request = compact_request(Announce_address,
                                              Info_hash,
                                              Peer_id_encoded,
                                              Length),
            {ok, 200, Compact_response} = send_request(Compact_request),
            {ok, Response} = parse_response(Compact_response)
    end,
    Response.


send_request(Request) ->
    inets:start(),
    try
        {ok, {{_, Code, _}, _, Response}} = httpc:request(get,
                                                          {Request,
                                                           [{"Accept",
                                                             "text/plain"}]},
                                                          [],
                                                          [{sync, true},
                                                           {headers_as_is, true}]),
        {ok, Code, Response}
    catch
        Exception:Reason -> {error, Exception, Reason}
    after
        inets:stop()
    end.

basic_request(Announce_address, Info_hash, Peer_id_encoded, Length) ->
    lists:concat([binary_to_list(Announce_address), '?',
                  "info_hash=", Info_hash,
                  "&peer_id=", Peer_id_encoded,
                  "&port=6882",
                  "&uploaded=0",
                  "&downloaded=0",
                  "&left=", Length,
                  "&event=started"]).

compact_request(Announce_address, Info_hash, Peer_id_encoded, Length) ->
    lists:concat([binary_to_list(Announce_address), '?',
                  "info_hash=", Info_hash,
                  "&peer_id=", Peer_id_encoded,
                  "&port=6882",
                  "&uploaded=0",
                  "&downloaded=0",
                  "&left=", Length,
                  "&event=started",
                  "&compact=1"]).

parse_response(Response_encoded) ->
    {ok, Response_decoded} = decode(Response_encoded),
    parse_decoded_response(Response_decoded, #announce_response{}).

decode(Response) ->
    try
        {ok, {{dict, Response_decoded}, _}} = bencode:decode(Response),
        {ok, Response_decoded}
    catch
        Exception:Reason -> {Exception, Reason}
    end.

parse_decoded_response([], Record) ->
    {ok, Record};
parse_decoded_response([{<<"complete">>, Value}|Tail], Record) ->
    New_record = Record#announce_response{complete=Value},
    parse_decoded_response(Tail, New_record);
parse_decoded_response([{<<"incomplete">>, Value}|Tail], Record) ->
    New_record = Record#announce_response{incomplete=Value},
    parse_decoded_response(Tail, New_record);
parse_decoded_response([{<<"interval">>, Value}|Tail], Record) ->
    New_record = Record#announce_response{interval=Value},
    parse_decoded_response(Tail, New_record);
parse_decoded_response([{<<"peers">>, Value}|Tail], Record) ->
    {ok, Peers} = parse_peers(Value, []),
    New_record = Record#announce_response{peers=Peers},
    parse_decoded_response(Tail, New_record).

parse_peers(<<>>, Acc) ->
    {ok, Acc};
parse_peers(<<Ip:4/big-binary-unit:8, Port:2/big-binary-unit:8, Tail/binary>>, Acc) ->
    Peer = #peer{ip=binary_to_list(Ip), port=binary_to_list(Port)},
    parse_peers(Tail, [Peer|Acc]).