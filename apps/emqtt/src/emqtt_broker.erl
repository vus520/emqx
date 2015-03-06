%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqtt broker.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqtt_broker).

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

-export([version/0, uptime/0, description/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {started_at}).

-define(SYS_TOPICS, [
        % $SYS Broker Topics
        <<"$SYS/broker/version">>,
        <<"$SYS/broker/uptime">>, 
        <<"$SYS/broker/description">>,
        <<"$SYS/broker/timestamp">>,
                                     
        % $SYS Client Topics
        <<"$SYS/broker/clients/connected">>,
        <<"$SYS/broker/clients/disconnected">>,
        <<"$SYS/broker/clients/total">>,
        <<"$SYS/broker/clients/max">>,

        % $SYS Subscriber Topics
        <<"$SYS/broker/subscribers/total">>,
        <<"$SYS/broker/subscribers/max">>]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Options], []).

version() ->
    {ok, Version} = application:get_key(emqtt, vsn),
    Version.

description() ->
    {ok, Descr} = application:get_key(emqtt, description),
    Descr.

uptime() ->
    gen_server:call(?SERVER, uptime).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Options]) ->
    % Create $SYS Topics
    [emqtt_pubsub:create(Topic) || Topic <- ?SYS_TOPICS],
    ets:new(?MODULE, [set, public, name_table, {write_concurrency, true}]),
    {ok, #state{started_at = os:timestamp()}}.

handle_call(uptime, _From, State = #state{started_at = Ts}) ->
    Secs = timer:now_diff(os:timestamp(), Ts) div 1000000,
    {reply, format(seconds, Secs), State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
format(seconds, Secs) when Secs < 60 ->
    integer_to_list
    <<(integer_to_list(Secs), 

    

