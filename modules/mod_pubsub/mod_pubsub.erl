%% @author Arjan Scherpenisse <arjan@scherpenisse.net>
%% @copyright 2009 Arjan Scherpenisse
%% @date 2010-01-31
%% @doc Content sharing over XMPP.

%% Copyright 2009 Arjan Scherpenisse
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(mod_pubsub).
-author("Arjan Scherpenisse <arjan@scherpenisse.net>").
-behaviour(gen_server).

-mod_title("Publish/subscribe").
-mod_description("Provides implementation for content sharing over XMPP.").
-mod_prio(1000).


%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/1]).

%% interface functions
-export([
         subscribe_to_url/2
]).

-record(state, {context, session, jid, pubsub_domain}).

-include_lib("zotonic.hrl").

-include("exmpp.hrl"). 
-include("exmpp_client.hrl").


-define(ATOM_NS, 'http://www.w3.org/2005/Atom').


%%====================================================================
%% API
%%====================================================================
%% @spec start_link(Args) -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
start_link(Args) when is_list(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore               |
%%                     {stop, Reason}
%% @doc Initiates the server.
init(Args) ->
    process_flag(trap_exit, true),
    {context, Context} = proplists:lookup(context, Args),
    zotonic:ensure_started(exmpp),
    z_notifier:observe(rsc_update_done, self(), Context),
    z_notifier:observe(rsc_delete, self(), Context),

    z_notifier:observe(subscribe_to_url, self(), Context),

    Domain = m_config:get_value(?MODULE, pubsub_domain, "pubsub." ++ z_dispatcher:hostname(Context), Context),
    State = case exmpp_jid:parse(m_config:get_value(?MODULE, jid, Context)) of
                undefined ->
                    C1 = z_session_manager:broadcast(#broadcast{type="error", message="Module has not been configured, not starting pubsub client.", title="Pubsub", stay=false}, Context),
                    #state{context=z_context:new(C1)};
                _ ->
                    connect(#state{context=z_acl:sudo(z_context:new(Context)), pubsub_domain=Domain})
            end,
	{ok, State}.


%% Description: Handling call messages

%% @doc Subscribe to a URL.
handle_call({{subscribe_to_url, Url}, _Context}, _From, State) ->
    Response = subscribe_to_url1(Url, State),
    {reply, Response, State};
%% @doc Trap unknown calls
handle_call(Message, _From, State) ->
    {stop, {unknown_call, Message}, State}.


%% @doc Trap unknown casts
handle_cast({{rsc_update_done, delete, _Id, _, _}, _Ctx}, State) ->
    %% After delete; do nothing.
    {noreply, State};

handle_cast({{rsc_update_done, _, Id, _, _}, _Ctx}, State=#state{context=Context}) ->
    case is_publishable(Id, Context) of
        false ->
            %% Check if has node
            case get_pubsub_node(Id, Context) of
                undefined ->
                    {noreply, State};
                _Node ->
                    %% Unpublish
                    ok = delete_notification(Id, false, State),
                    {noreply, State}
            end;
        true ->
            case get_pubsub_node(Id, Context) of
                undefined ->
                    ok = create_pubsub_node(Id, State);
                    %%ok = publish(Id, State); % When a node is created, this will set the 'pubsub_node' prop, which will trigger a publish.
                _ ->
                    ok = publish(Id, State)
            end,
            {noreply, State}
    end;

%% @doc Just before rsc delete; send delete notification.
handle_cast({{rsc_delete, Id}, _Ctx}, State=#state{context=Context}) ->
    case m_rsc:p(Id, is_authoritative, Context) of
        true ->
            %% Deleting authoritative content
            case is_publishable(Id, Context) of
                false ->
                    {noreply, State};
                true ->
                    case get_pubsub_node(Id, Context) of
                        undefined ->
                            {noreply, State};
                        _Node ->
                            ok = delete_notification(Id, true, State),
                            {noreply, State}
                    end
            end;

        false ->
            %% Deleting non-authoritative content
            case get_pubsub_subscription(Id, Context) of
                undefined ->
                    {noreply, State};
                Details ->
                    {Service, Node, _SubscriptionId} = Details,
                    ok = unsubscribe_node(Service, Node, State),
                    {noreply, State}
            end
    end;

%% handle_cast({{subscribe_to_url, Url}, _Ctx}, State) ->
%%     ok = subscribe_to_url(Url, State),
%%     {noreply, State};

handle_cast(Message, State) ->
    {stop, {unknown_cast, Message}, State}.


%% @doc Handling all non call/cast messages
handle_info({'EXIT', _Pid, tcp_closed}, State=#state{session=Session}) ->
    %% Restart
    exmpp_session:stop(Session),
    {stop, restarting, State};

handle_info(#received_packet{packet_type='message'}=Packet, State) ->
    process_received_packet(Packet, State),
    {noreply, State};

handle_info(_Info, State) ->
    ?DEBUG(_Info),
    {noreply, State}.

%% @spec terminate(Reason, State) -> void()
terminate(_Reason, #state{session=Session,context=Context}) ->
    exmpp_session:stop(Session),
    z_notifier:detach(rsc_update_done, self(), Context),
    z_notifier:detach(rsc_delete, self(), Context),
    z_notifier:detach(subscribe_to_url, self(), Context),
    ok.

%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% support functions
%%====================================================================


connect(State) ->
    Session = exmpp_session:start_link(),

    JID = exmpp_jid:parse(m_config:get_value(?MODULE, jid, State#state.context)),
    Password = z_convert:to_list(m_config:get_value(?MODULE, password, State#state.context)),

    ServerHost = z_convert:to_list(m_config:get_value(?MODULE, server_host, exmpp_jid:domain(JID), State#state.context)),
    ServerPort = z_convert:to_integer(m_config:get_value(?MODULE, server_port, "5222", State#state.context)),

    exmpp_session:auth_basic_digest(Session, JID, Password),
    State1 = State#state{session=Session, jid=JID},

    %% Connect in standard TCP:
    try
            exmpp_session:connect_TCP(Session, ServerHost, ServerPort),
            login(State1)
    catch
        throw:{socket_error, econnrefused} ->
            z_session_manager:broadcast(#broadcast{type="error", message="Connection failure. Will try again in 30 seconds.", title="Pubsub", stay=false}, State#state.context),
            timer:sleep(30000),
            connect(State)
    end.

login(State=#state{session=Session}) ->
    try
        exmpp_session:login(Session),
        exmpp_session:send_packet(Session, exmpp_presence:set_status(exmpp_presence:available(), "mod_pubsub ready.")),
        State
    catch
        throw:{auth_error, 'not-authorized'} ->
            z_session_manager:broadcast(#broadcast{type="error", message="Unauthorized. Will try again in 30 seconds.", title="Pubsub", stay=false}, State#state.context),
            timer:sleep(30000),
            login(State)
    end.


%%
%% Publish functions
%%

%% @doc Whether given rsc is publishable.
is_publishable(Id, Context) ->
    m_rsc:p(Id, is_authoritative, Context) andalso m_rsc:p(Id, is_published, Context).

%% Return the pubsub node for this id.
get_pubsub_node(Id, Context) ->
    m_rsc:p(Id, pubsub_node, Context).

%% @doc Set the pubsub node
set_pubsub_node(Id, Node, Context) ->
    m_rsc:update(Id, [{pubsub_node, Node}], Context).

%% @doc Create the pubsub node for given id.
create_pubsub_node(Id, #state{jid=JID,session=Session,context=Context,pubsub_domain=Domain}) ->
    IQ = exmpp_client_pubsub:create_instant_node(Domain),
    PacketId = binary_to_list(exmpp_session:send_packet(Session, exmpp_stanza:set_sender(IQ, JID))),
    receive
        #received_packet{id=PacketId, raw_packet=Raw} ->
            case exmpp_iq:is_error(Raw) of
                true -> 
                    ?DEBUG(Raw),
                    error;
                _ ->
                    %% Get the node name
                    PubSubEl = exmpp_xml:get_element_by_ns(Raw, 'http://jabber.org/protocol/pubsub'),
                    [Result] = exmpp_xml:get_elements(PubSubEl, 'create'),
                    case exmpp_xml:get_attribute_as_list(Result, node, undefined) of
                        undefined ->
                            ?DEBUG(Raw),
                            ?DEBUG("node not found in result!"),
                            error;
                        Node ->
                            set_pubsub_node(Id, Node, Context),
                            ok
                    end
            end
    end.
    

publish(Id, #state{jid=JID,session=Session,context=Context,pubsub_domain=Domain}) ->
    Atom = atom_convert:resource_to_atom(m_rsc_export:full(Id, Context)),
    Entry = exmpp_xml:parse_document(Atom),
    Node = get_pubsub_node(Id, Context),
    IQ = exmpp_client_pubsub:publish(Domain, Node, Entry),
    PacketId = binary_to_list(exmpp_session:send_packet(Session, exmpp_stanza:set_sender(IQ, JID))),
    receive
        #received_packet{id=PacketId, raw_packet=Raw} ->
            ?DEBUG(Raw),
            case exmpp_iq:is_error(Raw) of
                true -> error;
                _ -> ok
            end
    end.


delete_notification(Id, RscIsDeleted, #state{jid=JID,session=Session,context=Context,pubsub_domain=Domain}) ->
    Node = get_pubsub_node(Id, Context),
    ?DEBUG("DELETE NOTIFICATION"),
    ?LOG("~p - ~p~n", [Id, Node]),
    IQ = exmpp_client_pubsub:delete_node(Domain, Node),
    PacketId = binary_to_list(exmpp_session:send_packet(Session, exmpp_stanza:set_sender(IQ, JID))),
    receive
        #received_packet{id=PacketId, raw_packet=Raw} ->
            case exmpp_iq:is_error(Raw) of
                true -> 
                    ?DEBUG("Error delete"),
                    ?DEBUG(IQ),
                    ?DEBUG(Raw),
                    error;
                _ -> 
                    case RscIsDeleted of
                        false -> set_pubsub_node(Id, undefined, Context);
                        true -> ok
                    end,
                    ?DEBUG("Delete OK"),
                    ok
            end
    end.


%%
%% Subscribe functions
%%

%% PUBLIC 

get_pubsub_subscription(Id, Context) ->
    m_rsc:p(Id, pubsub_subscription, Context).


%% @doc Subscribe to a URL, 
subscribe_to_url(Url, Context) ->
    z_notifier:first({subscribe_to_url, Url}, Context).

%% %% @doc Subscribe to a URL, performing discovery first.
subscribe_to_url1(Url, State) ->

    %% Discover the resource URL
    RscUrl = case z_xmpp:discover_resource_uri(Url, State#state.context) of
                 {ok, U} -> U;
                 undefined -> Url;
                 {error, E} -> throw({error, E})
             end,

    %% URI should not already exist locally
    case m_rsc:uri_lookup(RscUrl, State#state.context) of
        undefined -> ok;
        _ -> throw({error, {rsc_already_exists, RscUrl}})
    end,

    case z_xmpp:discover_xmpp_uri(Url, State#state.context) of
        {ok, Uri} ->
            {Jid, _Action, Args} = z_xmpp:parse_xmpp_uri(Uri),
            case proplists:get_value("node", Args) of
                undefined ->
                    {error, missing_node_in_xmpp_uri};
                Node ->
                    %% Create the rsc
                    {ok, Id} = m_rsc_import:create_empty(RscUrl, [{pubsub_xmpp_uri, Uri}], State#state.context),
                    %% Do the subscription
                    {ok, Id, subscribe_node(exmpp_jid:to_list(Jid), Node, State)}
            end;

        undefined ->
            %% Not published/not subscribable
            {error, xmpp_uri_not_found};
        {error, Er} ->
            %% Some other error
            {error, Er}
    end.


subscribe_node(Service, Node, #state{jid=JID,session=Session}) ->
    IQ = exmpp_client_pubsub:subscribe(exmpp_jid:to_list(JID), Service, Node),
    PacketId = binary_to_list(exmpp_session:send_packet(Session, exmpp_stanza:set_sender(IQ, JID))),
    receive
        #received_packet{id=PacketId, raw_packet=Raw} ->
            case exmpp_iq:is_error(Raw) of
                true ->
                    ?DEBUG(Raw),
                    error;
                _ ->
                    ?DEBUG("Subscribe OK"),
                    subscribed
            end
    end.


%% %% @doc Subscribe to a URL, 
unsubscribe_node(Service, Node, #state{jid=JID,session=Session}) ->
    IQ = exmpp_client_pubsub:unsubscribe(exmpp_jid:to_list(JID), Service, Node),
    PacketId = binary_to_list(exmpp_session:send_packet(Session, exmpp_stanza:set_sender(IQ, JID))),
    receive
        #received_packet{id=PacketId, raw_packet=Raw} ->
            case exmpp_iq:is_error(Raw) of
                true ->
                    ?DEBUG(Raw),
                    error;
                _ ->
                    ?DEBUG("Unsubscribe OK"),
                    ok
            end
    end.



%%
%% XMPP received packet processing
%%
process_received_packet(#received_packet{raw_packet=Raw}, State) ->
    case exmpp_xml:get_element(Raw, ?NS_PUBSUB_EVENT, 'event') of
        undefined ->
            ?DEBUG("Received non-pubsub packet"),?DEBUG(Raw),
            undefined;
        Event ->
            Element = exmpp_xml:get_element_by_ns(Event, ?NS_PUBSUB_EVENT),
            ?DEBUG(Element),
            case exmpp_xml:get_name_as_atom(Element) of
                items ->
                    exmpp_xml:foreach(fun(_, Item) -> process_pubsub_item(Item, State) end, Element);
                delete ->
                    ?DEBUG("Delete notification")
            end
    end.

process_pubsub_item(Item, #state{context=Context}) ->
    [Payload] = exmpp_xml:get_child_elements(Item),
    case exmpp_xml:get_ns_as_atom(Payload) of
        ?ATOM_NS ->
            %% Process atom payload
            AtomXML = iolist_to_binary(exmpp_xml:document_to_iolist(Payload)),
            Checksum = list_to_binary(lists:flatten([io_lib:format("~2.16.0b",[N])||N<-binary_to_list(crypto:sha(AtomXML))])),
            RscImport = atom_convert:atom_to_resource(AtomXML),

            %% Import resource
            {uri, Uri} = proplists:lookup(uri, RscImport),
            Id = case m_rsc:uri_lookup(Uri, Context) of
                     undefined -> throw({error, {unknown_rsc, Uri}});
                     TheId -> TheId
                 end,

            case m_rsc:p(Id, pubsub_payload_checksum, Context) of
                Checksum ->
                    ?DEBUG("Content not changed");
                _ ->
                    try
                        m_rsc_import:import(RscImport, Context),
                        m_rsc_update:update(Id, [{pubsub_payload_checksum, Checksum}], [{acl_check, false}], Context),
                        ?DEBUG("imported!")
                    catch
                        _: {error, Msg} ->
                            ?DEBUG("Error importing"),
                            ?DEBUG(Msg)
                    end
            end,
            ok;
        Unknown ->
            throw({error, {unknown_pubsub_payload_ns, Unknown}})
    end.


%%node_name(Id) ->
%%    lists:flatten(io_lib:format("/home/testsandbox/zotonic/id-~p", [Id])).


%% DEBUG: mod_pubsub:198  {xmlel,'jabber:client',[],iq,
%%                         [{xmlattr,undefined,from,<<"pubsub.testsandbox">>},
%%                          {xmlattr,undefined,to,
%%                           <<"zotonic@testsandbox/PubSub">>},
%%                          {xmlattr,undefined,id,<<"pubsub-396429316">>},
%%                          {xmlattr,undefined,type,<<"result">>}],
%%                         [{xmlel,'http://jabber.org/protocol/pubsub',
%%                           [{'http://jabber.org/protocol/pubsub',none}],
%%                           pubsub,[],
%%                           [{xmlel,'http://jabber.org/protocol/pubsub',[],
%%                             create,
%%                             [{xmlattr,undefined,node,
%%                               <<"/home/testsandbox/zotonic/286723704">>}],
%%                             []}]}]}
