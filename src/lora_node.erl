%
% This file is part of AtomVM.
%
% Copyright 2021 Fred Dushin <fred@dushin.net>
%
% Licensed under the Apache License, Version 2.0 (the "License");
% you may not use this file except in compliance with the License.
% You may obtain a copy of the License at
%
%    http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS,
% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% See the License for the specific language governing permissions and
% limitations under the License.
%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(lora_node).

-export([start/2, call/3, call/4, cast/3, multicast/2, get_lora/1]).

%% gen_server
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-behavior(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_TIMEOUT_MS, 15000).

start(Name, Config) ->
    gen_server:start(?MODULE, {Name, Config}, []).

cast(LauraNode, ToNodeName, Term) ->
    ?LOG_DEBUG("Casting to ~p: ~p ...", [ToNodeName, Term]),
    gen_server:cast(LauraNode, {cast, ToNodeName, Term}).

multicast(LauraNode, Term) ->
    gen_server:cast(LauraNode, {multicast, Term}).

call(LoraNode, ToNodeName, Term) ->
    call(LoraNode, ToNodeName, Term, undefined).

call(LoraNode, ToNodeName, Term, undefined) ->
    gen_server:call(LoraNode, {call, ToNodeName, Term, undefined}, ?DEFAULT_TIMEOUT_MS);
call(LoraNode, ToNodeName, Term, TimeoutMs) ->
    gen_server:call(LoraNode, {call, ToNodeName, Term, TimeoutMs}, TimeoutMs).

get_lora(LoraNode) ->
    gen_server:call(LoraNode, get_lora).

%%%
%%% gen_server implementation
%%%

-record(state, {
    lora,
    config,
    name,
    outstanding_requests = #{},
    n = 0
}).

%% @hidden
init({Name, Config}) ->
    ?LOG_DEBUG("init({~p ~p})", [Name, Config]),
    LoraConfig = maps:get(lora, Config),
    NewLoraConfig = LoraConfig#{
        receive_handler => self()
    },
    ?LOG_DEBUG("Starting lora with ~p", [NewLoraConfig]),
    case lora:start(NewLoraConfig) of
        {ok, Lora} ->
            State = #state{lora=Lora, config=Config#{lora => NewLoraConfig}, name=Name},
            ?LOG_DEBUG("Initialized LoraNode.  State=~p", [State]),
            {ok, State};
        Error ->
            Error
    end.

%% @hidden
handle_cast({cast, ToNodeName, Term}, State) ->
    ?LOG_DEBUG("handle_cast: {cast, ~p, ~p}", [ToNodeName, Term]),
    NewState = do_cast(State, ToNodeName, Term),
    {noreply, NewState};
handle_cast(Message, State) ->
    io:format("Unhandled cast.  Message: ~p~n", [Message]),
    {noreply, State}.

%% @hidden
handle_call({call, ToNodeName, Term, TimeoutMs}, From, State) ->
    ?LOG_DEBUG("handle_call: {call, ~p, ~p, ~p}", [ToNodeName, Term, TimeoutMs]),
    NewState = do_call(State, From, ToNodeName, Term, TimeoutMs),
    {noreply, NewState};
% handle_call({multicast, Term}, From, State) ->
%     ?LOG_DEBUG("handle_multicast: {multicast, ~p}", [Term]),
%     NewState = do_multicast(State, From, Term),
%     {noreply, NewState};
handle_call(get_lora, _From, State) ->
    {reply, State#state.lora, State};
handle_call(Request, _From, State) ->
    io:format("lora_node Unhandled call.  Request: ~p~n", [Request]),
    {reply, error, State}.

%% @hidden
handle_info({lora_receive, _Lora, Message, QoS}, State) ->
    ?LOG_DEBUG("handle_info: {lora_receive, _Lora, ~p, _QoS}", [Message]),
    % diag:print_proc_infos(),
    try
        do_handle_message(State, Message, QoS)
    catch
        _:E ->
            io:format("Error handling received message: ~p~n", [E])
    end,
    {noreply, State};
handle_info({request_completed, RequestId}, State) ->
    ?LOG_DEBUG("handle_info: {request_completed, ~p}", [RequestId]),
    OutstandingRequests = State#state.outstanding_requests,
    {noreply, State#state{outstanding_requests=maps:remove(RequestId, OutstandingRequests)}};
handle_info(Message, State) ->
    io:format("Unhandled info.  Message: ~p~n", [Message]),
    {noreply, State}.

%% @hidden
terminate(_Reason, _State) ->
    ok.

%%%
%%% private
%%%

-define(ERLANG_ENCODING, 16#01).
-define(MSG_TYPE_NET, 16#00).
-define(MSG_TYPE_APP, 16#F0).


%%%
%%% Magic byte
%%%
%%% +-+-+-+-+-+-+-+-+
%%% |7|6|5|4|3|2|1|0|
%%% +-+-+-+-+-+-+-+-+
%%% |<----->|<----->|
%%%   msg    encoding
%%%   type

do_call(State, From, ToNodeName, Term, TimeoutMs) ->
    N = State#state.n,
    RequestId = create_request_id(State#state.name, ToNodeName),
    Payload = create_lora_call_message(RequestId, Term),
    Self = self(),
    ActualTimeoutMs = case TimeoutMs of undefined -> maps:get(timeout_ms, State#state.config, ?DEFAULT_TIMEOUT_MS); _ -> TimeoutMs end,
    Pid = spawn(fun() -> do_call_async(Self, ActualTimeoutMs, State#state.lora, RequestId, Payload, From) end),
    OutstandingRequests = State#state.outstanding_requests,
    State#state{outstanding_requests=OutstandingRequests#{RequestId => Pid}, n=N+1}.

do_cast(State, ToNodeName, Term) ->
    N = State#state.n,
    RequestId = create_request_id(State#state.name, ToNodeName),
    Payload = create_lora_cast_message(RequestId, Term),
    ?LOG_DEBUG("spawning do_cast_async with payload ~p", [Payload]),
    spawn(fun() -> do_cast_async(State#state.lora, Payload) end),
    State#state{n=N+1}.

create_request_id(FromNodeName, ToNodeName) ->
    {FromNodeName, ToNodeName, 0}. %%atomvm:random()}.

create_lora_call_message(RequestId, Term) ->
    create_lora_app_message({call, {RequestId, Term}}).

create_lora_cast_message(RequestId, Term) ->
    create_lora_app_message({cast, {RequestId, Term}}).

create_lora_app_message(Msg) ->
    Magic = ?MSG_TYPE_APP bor ?ERLANG_ENCODING,
    Message = term_to_binary(Msg),
    <<
        Magic:8,
        Message/binary
    >>.

do_call_async(LoraNode, TimeoutMs, Lora, RequestId, Payload, From) ->
    lora:broadcast(Lora, Payload),
    receive
        {RequestId, Reply, _QoS} ->
            ?LOG_DEBUG("I got a reply from ~p: ~p", [From, Reply]),
            gen_server:reply(From, Reply)
    after TimeoutMs ->
        ?LOG_DEBUG("oh well, timed out... ~p", [self()]),
        gen_server:reply(From, {error, timeout})
    end,
    LoraNode ! {request_completed, RequestId}.

do_cast_async(Lora, Payload) ->
    ?LOG_DEBUG("Broadcasting payload to Lora ~p", [Lora]),
    lora:broadcast(Lora, Payload).



%%%
%%% Message handling (receive side)
%%%

do_handle_message(_State, <<"">>, _QoS) ->
    ?LOG_DEBUG("Empty payload", []),
    empty_payload;
do_handle_message(State, Payload, QoS) ->
    <<Magic:8, Msg/binary>> = Payload,
    MsgType = Magic band 16#F0,
    case MsgType of
        ?MSG_TYPE_NET ->
            ?LOG_DEBUG("NET msg type", []),
            handle_net_message(State, Magic band 16#0F, Msg, QoS);
        ?MSG_TYPE_APP ->
            ?LOG_DEBUG("APP msg type", []),
            handle_app_message(State, Magic band 16#0F, Msg, QoS);
        _ ->
            ?LOG_DEBUG("Unknown msg type", []),
            unknown_msg_type
    end.

handle_net_message(_State, _Encoding, _Msg, _QoS) ->
    unimplemented.

handle_app_message(State, Encoding, Msg, QoS) ->
    case Encoding of
        ?ERLANG_ENCODING ->
            ?LOG_DEBUG("Erlang encoding", []),
            {MsgType, Message} = binary_to_term(Msg),
            handle_application_message_type(MsgType, State, Message, QoS);
        _ ->
            ?LOG_DEBUG("Unknown encoding", []),
            unknown_encoding
    end.

handle_application_message_type(cast, State, {RequestId, Term}, QoS) ->
    ?LOG_DEBUG("handle_message_type: {call, ~p}", [{RequestId, Term}]),
    {FromNodeName, ToNodeName, _Ref} = RequestId,
    MyName = State#state.name,
    case ToNodeName of
        MyName ->
            ?LOG_DEBUG("Cast message was intended for me ~p", [MyName]),
            case maps:get(cast_handler, State#state.config, undefined) of
                undefined ->
                    ?LOG_DEBUG("No cast handler for ~p", [MyName]),
                    no_cast_handler;
                CastHandler ->
                    ?LOG_DEBUG("found cast handler", []),
                    CastHandler(Term, #{from => FromNodeName, qos => QoS})
            end;
        _SomeoneElse ->
            ?LOG_DEBUG("Cast message was intended for someone else", []),
            intended_for_someone_else
    end;
handle_application_message_type(call, State, {RequestId, Term}, QoS) ->
    ?LOG_DEBUG("handle_message_type: {call, ~p}", [{RequestId, Term}]),
    {FromNodeName, ToNodeName, _Ref} = RequestId,
    MyName = State#state.name,
    case ToNodeName of
        MyName ->
            ?LOG_DEBUG("Call message was intended for me ~p", [MyName]),
            case maps:get(call_handler, State#state.config, undefined) of
                undefined ->
                    ?LOG_DEBUG("No call handler for ~p", [MyName]),
                    no_call_handler;
                CallHandler ->
                    ?LOG_DEBUG("found call handler", []),
                    Reply = CallHandler(Term, #{from => FromNodeName, qos => QoS}),
                    ?LOG_DEBUG("reply: ~p", [Reply]),
                    ReplyMessage = create_lora_reply_message(RequestId, Reply),
                    ?LOG_DEBUG("broadcasting reply message: ~p", [ReplyMessage]),
                    lora:broadcast(State#state.lora, ReplyMessage)
            end;
        _SomeoneElse ->
            ?LOG_DEBUG("Call message was intended for someone else", []),
            intended_for_someone_else
    end;
handle_application_message_type(reply, State, {RequestId, Reply}, QoS) ->
    ?LOG_DEBUG("handling reply ~p", [{RequestId, Reply}]),
    {FromNodeName, _ToNodeName, _Ref} = RequestId,
    MyName = State#state.name,
    case FromNodeName of
        MyName ->
            ?LOG_DEBUG("Reply message was intended for me ~p", [MyName]),
            case maps:get(RequestId, State#state.outstanding_requests, undefined) of
                undefined ->
                    maybe_request_timed_out;
                Pid ->
                    ?LOG_DEBUG("found pid waiting for reply: ~p", [Pid]),
                    Pid ! {RequestId, Reply, QoS}
            end;
        _SomeoneElse ->
            ?LOG_DEBUG("Reply message was intended for someone else", []),
            ignore
    end.


create_lora_reply_message(RequestId, Term) ->
    create_lora_app_message({reply, {RequestId, Term}}).
