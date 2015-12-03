%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2015 eMQTT.IO, All Rights Reserved.
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
%%% @doc emqttd pubsub
%%%
%%% @author Feng Lee <feng@emqtt.io>
%%%
%%%-----------------------------------------------------------------------------
-module(emqttd_pubsub).

-behaviour(gen_server2).

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

-include("emqttd_internal.hrl").

%% Mnesia Callbacks
-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).
-copy_mnesia({mnesia, [copy]}).

%% API Exports 
-export([start_link/3]).

-export([create/1, subscribe/1, subscribe/2,
         unsubscribe/1, unsubscribe/2, publish/1]).

%% Local node
-export([match/1]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ifdef(TEST).
-compile(export_all).
-endif.

-record(state, {pool, id}).

-define(ROUTER, emqttd_router).

-define(HELPER, emqttd_pubsub_helper).

%%%=============================================================================
%%% Mnesia callbacks
%%%=============================================================================

mnesia(boot) ->
    %% Topic Table
    ok = emqttd_mnesia:create_table(topic, [
                {type, bag},
                {ram_copies, [node()]},
                {record_name, mqtt_topic},
                {attributes, record_info(fields, mqtt_topic)}]),
    RamOrDisc = case env(subscription) of
        disc -> disc_copies;
        _    -> ram_copies
    end,
    %% Subscription Table
    ok = emqttd_mnesia:create_table(subscription, [
                {type, bag},
                {RamOrDisc, [node()]},
                {record_name, mqtt_subscription},
                {attributes, record_info(fields, mqtt_subscription)}]);

mnesia(copy) ->
    ok = emqttd_mnesia:copy_table(topic),
    ok = emqttd_mnesia:copy_table(subscription).

env(Key) ->
    proplists:get_value(Key, emqttd_broker:env(pubsub)).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Start one pubsub server
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Pool, Id, Opts) -> {ok, pid()} | ignore | {error, any()} when
    Pool :: atom(),
    Id   :: pos_integer(),
    Opts :: list(tuple()).
start_link(Pool, Id, Opts) ->
    gen_server2:start_link({local, name(Id)}, ?MODULE, [Pool, Id, Opts], []).

name(Id) ->
    list_to_atom("emqttd_pubsub_" ++ integer_to_list(Id)).

%%------------------------------------------------------------------------------
%% @doc Create Topic.
%% @end
%%------------------------------------------------------------------------------
-spec create(Topic :: binary()) -> ok | {error, Error :: any()}.
create(Topic) when is_binary(Topic) ->
    Record = #mqtt_topic{topic = Topic, node = node()},
    case mnesia:transaction(fun add_topic/1, [Record]) of
        {atomic, ok}     -> ok;
        {aborted, Error} -> {error, Error}
    end.

%%------------------------------------------------------------------------------
%% @doc Subscribe Topics
%% @end
%%------------------------------------------------------------------------------
-spec subscribe({Topic, Qos} | list({Topic, Qos})) ->
    {ok, Qos | list(Qos)} | {error, any()} when
    Topic   :: binary(),
    Qos     :: mqtt_qos() | mqtt_qos_name().
subscribe({Topic, Qos}) ->
    subscribe([{Topic, Qos}]);
subscribe(TopicTable) when is_list(TopicTable) ->
    call({subscribe, {undefined, self()}, fixqos(TopicTable)}).

-spec subscribe(ClientId, {Topic, Qos} | list({Topic, Qos})) ->
    {ok, Qos | list(Qos)} | {error, any()} when
    ClientId :: binary(),
    Topic    :: binary(),
    Qos      :: mqtt_qos() | mqtt_qos_name().
subscribe(ClientId, {Topic, Qos}) when is_binary(ClientId) ->
    subscribe(ClientId, [{Topic, Qos}]);
subscribe(ClientId, TopicTable) when is_binary(ClientId) andalso is_list(TopicTable) ->
    call({subscribe, {ClientId, self()}, fixqos(TopicTable)}).

fixqos(TopicTable) ->
    [{Topic, ?QOS_I(Qos)} || {Topic, Qos} <- TopicTable].

call(Request) ->
    PubSub = gproc_pool:pick_worker(pubsub, self()),
    gen_server2:call(PubSub, Request, infinity).

%%------------------------------------------------------------------------------
%% @doc Unsubscribe Topic or Topics
%% @end
%%------------------------------------------------------------------------------
-spec unsubscribe(binary() | list(binary())) -> ok.
unsubscribe(Topic) when is_binary(Topic) ->
    unsubscribe([Topic]);
unsubscribe(Topics = [Topic|_]) when is_binary(Topic) ->
    cast({unsubscribe, {undefined, self()}, Topics}).

-spec unsubscribe(binary(), binary() | list(binary())) -> ok.
unsubscribe(ClientId, Topic) when is_binary(ClientId) andalso is_binary(Topic) ->
    unsubscribe(ClientId, [Topic]);
unsubscribe(ClientId, Topics = [Topic|_]) when is_binary(Topic) ->
    cast({unsubscribe, {ClientId, self()}, Topics}).

cast(Msg) ->
    PubSub = gproc_pool:pick_worker(pubsub, self()),
    gen_server2:cast(PubSub, Msg).

%%------------------------------------------------------------------------------
%% @doc Publish to cluster nodes
%% @end
%%------------------------------------------------------------------------------
-spec publish(Msg :: mqtt_message()) -> ok.
publish(Msg = #mqtt_message{from = From}) ->
    trace(publish, From, Msg),
    Msg1 = #mqtt_message{topic = Topic}
               = emqttd_broker:foldl_hooks('message.publish', [], Msg),

    %% Retain message first. Don't create retained topic.
    case emqttd_retainer:retain(Msg1) of
        ok ->
            %% TODO: why unset 'retain' flag?
            publish(Topic, emqttd_message:unset_flag(Msg1));
        ignore ->
            publish(Topic, Msg1)
     end.

publish(Topic, Msg) when is_binary(Topic) ->
	lists:foreach(fun(#mqtt_topic{topic=Name, node=Node}) ->
                    rpc:cast(Node, ?ROUTER, route, [Name, Msg])
                  end, match(Topic)).

%%------------------------------------------------------------------------------
%% @doc Match Topic Name with Topic Filters
%% @end
%%------------------------------------------------------------------------------
-spec match(Topic :: binary()) -> [mqtt_topic()].
match(Topic) when is_binary(Topic) ->
	MatchedTopics = mnesia:async_dirty(fun emqttd_trie:match/1, [Topic]),
	lists:append([mnesia:dirty_read(topic, Name) || Name <- MatchedTopics]).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

init([Pool, Id, Opts]) ->
    ?ROUTER:init(Opts),
    ?GPROC_POOL(join, Pool, Id),
    process_flag(priority, high),
    {ok, #state{pool = Pool, id = Id}}.

handle_call({subscribe, {SubId, SubPid}, TopicTable}, _From, State) ->
    %% Clean aging topics
    ?HELPER:clean([Topic || {Topic, _Qos} <- TopicTable]),

    %% Add routes first
    ?ROUTER:add_routes(TopicTable, SubPid),

    %% Add topics
    Node = node(),
    TRecords = [#mqtt_topic{topic = Topic, node = Node} || {Topic, _Qos} <- TopicTable],
    
    %% Add subscriptions
    case mnesia:transaction(fun add_topics/1, [TRecords]) of
        {atomic, _} ->
            %%TODO: store subscription
            %% mnesia:async_dirty(fun add_subscriptions/2, [SubId, TopicTable]),
            {reply, {ok, [Qos || {_Topic, Qos} <- TopicTable]}, State};
        {aborted, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call(Req, _From, State) ->
    lager:error("Bad Request: ~p", [Req]),
	{reply, {error, badreq}, State}.

handle_cast({unsubscribe, {SubId, SubPid}, Topics}, State) ->
    %% Delete routes first
    ?ROUTER:delete_routes(Topics, SubPid),

    %% Remove subscriptions
    mnesia:async_dirty(fun remove_subscriptions/2, [SubId, Topics]),

    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("Bad Msg: ~p", [Msg]),
	{noreply, State}.

handle_info({'DOWN', _Mon, _Type, DownPid, _Info}, State) ->
    ?ROUTER:delete_routes(DownPid),
    {noreply, State, hibernate};

handle_info(Info, State) ->
    lager:error("Unexpected Info: ~p", [Info]),
	{noreply, State}.

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    ?GPROC_POOL(leave, Pool, Id).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

add_topics(Records) ->
    lists:foreach(fun add_topic/1, Records).

add_topic(TopicR = #mqtt_topic{topic = Topic}) ->
    case mnesia:wread({topic, Topic}) of
        [] ->
            ok = emqttd_trie:insert(Topic),
            mnesia:write(topic, TopicR, write);
        Records ->
            case lists:member(TopicR, Records) of
                true -> ok;
                false -> mnesia:write(topic, TopicR, write)
            end
    end.

add_subscriptions(undefined, _TopicTable) ->
    ok;
add_subscriptions(SubId, TopicTable) ->
    lists:foreach(fun({Topic, Qos}) ->
            %%TODO: this is not right...
            Subscription = #mqtt_subscription{subid = SubId, topic = Topic, qos = Qos},
            mnesia:write(subscription, Subscription, write)
        end,TopicTable).

remove_subscriptions(undefined, _Topics) ->
    ok;
remove_subscriptions(SubId, Topics) ->
    lists:foreach(fun(Topic) ->
         Pattern = #mqtt_subscription{subid = SubId, topic = Topic, qos = '_'},
         [mnesia:delete_object(subscription, Subscription, write)
            || Subscription <- mnesia:match_object(subscription, Pattern, write)]
     end, Topics).

%%%=============================================================================
%%% Trace Functions
%%%=============================================================================

trace(publish, From, _Msg) when is_atom(From) ->
    %% Dont' trace broker publish
    ignore;

trace(publish, From, #mqtt_message{topic = Topic, payload = Payload}) ->
    lager:info([{client, From}, {topic, Topic}],
               "~s PUBLISH to ~s: ~p", [From, Topic, Payload]).

