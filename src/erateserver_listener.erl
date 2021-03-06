-module(erateserver_listener).

-export([child_spec/0, configure_groups/0]).

%% Configuration proxy
conf(Key) ->
    erateserver:conf(Key).

conf(Key, Default) ->
    erateserver:conf(Key, Default).


%% Construct a child spec for an empty group list
%% This is used for starting the listener in erateserver root supervisor
%% before configuring any groups
child_spec() ->
    CowboyEnv = [{env, [{dispatch, make_dispatch([])}]}],
    Opts = [{max_keepalive, 100000}, {timeout, 300000}],
    Hooks = conf_hooks(),


    Ref = ?MODULE,
    NbAcceptors = conf(pool_size, 100),
    TransOpts = [{ip, {0,0,0,0,0,0,0,0}}, {port, conf(port)}, {max_connections, 100000}],
    ProtoOpts = CowboyEnv ++ Hooks ++ Opts,

    %% Aruments copied from Cowboy code, but we make a child spec for embedding
    %% instead of starting the listener in ranch's supervision tree
    ranch:child_spec(Ref, NbAcceptors, ranch_tcp, TransOpts, cowboy_protocol, ProtoOpts).


%% Reconfigure erater groups
configure_groups() ->
    Groups = conf(groups, []),
    ok = validate_groups(Groups),
    Dispatch = make_dispatch(Groups),
    cowboy:set_env(?MODULE, dispatch, Dispatch).



segment_blacklist() ->
    ["ping", "rpc", "admin"].

% Group config validation
validate_groups([]) ->
    ok;
validate_groups([{Name, UrlSegment, GroupConfig}|MoreGroups]) when is_atom(Name), is_list(UrlSegment), is_list(GroupConfig) ->
    % Seems legit. Go deeper
    StrippedSeg = string:strip(UrlSegment, both, $/),
    Blacklisted = lists:member(StrippedSeg, segment_blacklist()),
    ValidConfig = (length(erater_config:clean(GroupConfig)) > 2),
    case {Blacklisted, ValidConfig} of
        {false, true} ->
            validate_groups(MoreGroups); % ok
        {true, _} ->
            lager:critical("Blacklisted uri segment in erateserver config: ~p", [UrlSegment]),
            {error, {blacklisted, UrlSegment}};
        {_, false} ->
            lager:critical("Bad config for erateserver group ~w: ~p", [Name, GroupConfig]),
            {error, {bad_config, GroupConfig}}
    end;
validate_groups([BadGroup|_]) ->
    {error, {bad_group_definition, BadGroup}}.




make_dispatch(Groups) ->
    PathList = [configure_group(Group) || Group <- Groups],
    RPCList = [configure_rpc(Group) || Group <- Groups],
    AdminList = erateserver_admin:path_list(),
    DefPath = {'_', erateserver_handler, []},
    Host = {'_', PathList ++ RPCList ++ AdminList ++ [DefPath]},
    cowboy_router:compile([Host]).

configure_group({GroupName, UrlSegment, GroupConfig}) ->
    erater:configure(GroupName, GroupConfig),
    PathMatch = "/" ++ UrlSegment ++ "/:counter_name", 
    Mode = erater_config:mode(GroupConfig),
    {PathMatch, erateserver_handler, {Mode, GroupName}}.

configure_rpc({GroupName, UrlSegment, GroupConfig}) ->
    Shards = erater_config:shards(GroupConfig),
    erateserver_sup:add_proxies(GroupName, Shards),
    {"/rpc/" ++ UrlSegment, erateserver_subproto, GroupName}.

conf_hooks() ->
    case conf(log_access, false) of
        true -> [{onresponse, fun erateserver_log:access/4}];
        false -> []
    end.
