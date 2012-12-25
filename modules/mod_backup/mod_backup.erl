%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2010-2012 Marc Worrell
%% Date: 2010-02-11
%% @doc Backup module. Creates backup of the database and files.  Allows downloading of the backup.
%% Support creation of periodic backups.

%% Copyright 2010-2012 Marc Worrell
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

-module(mod_backup).
-author("Marc Worrell <marc@worrell.nl>").
-behaviour(gen_server).

-mod_title("Backup").
-mod_description("Make a backup of the database and files.").
-mod_prio(600).
-mod_provides([backup]).
-mod_depends([rest, admin]).
-mod_schema(1).

%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/1]).

%% interface functions
-export([
    observe_admin_menu/3,
    observe_rsc_update/3,
    start_backup/1,
    list_backups/1,
    backup_in_progress/1,
    file_exists/2,
    file_forbidden/2,
    check_configuration/0,
    manage_schema/2
]).

-include_lib("zotonic.hrl").
-include_lib("modules/mod_admin/include/admin_menu.hrl").


-record(state, {context, backup_start, backup_pid, timer_ref}).

% Interval for checking for new and/or changed files.
-define(BCK_POLL_INTERVAL, 3600 * 1000).



observe_admin_menu(admin_menu, Acc, Context) ->
    [
     #menu_item{id=admin_backup,
                parent=admin_modules,
                label=?__("Backup", Context),
                url={admin_backup},
                visiblecheck={acl, use, mod_backup}}
     
     |Acc].


observe_rsc_update(#rsc_update{action=update, id=Id, props=Props}, Acc, Context) ->
    m_backup_revision:save_revision(Id, Props, Context),
    Acc;
observe_rsc_update(_, Acc, _Context) ->
    Acc.


%% @doc Callback for controller_file_readonly.  Check if the file exists.
file_exists(File, Context) ->
    PathFile = filename:join([dir(Context), File]),
    case filelib:is_regular(PathFile) of 
    	true ->
    	    {true, PathFile};
    	false ->
    	    false
    end.


%% @doc Callback for controller_file_readonly.  Check if access is allowed.
file_forbidden(_File, Context) ->
    not z_acl:is_allowed(use, mod_admin_backup, Context).


%% @doc Start a backup
start_backup(Context) ->
    gen_server:call(z_utils:name_for_host(?MODULE, z_context:site(Context)), start_backup).
    
%% @doc List all backups present.  Newest first.
list_backups(Context) ->
    InProgress = gen_server:call(z_utils:name_for_host(?MODULE, z_context:site(Context)), in_progress_start),
    [ {F, D, D =:= InProgress} || {F,D} <- list_backup_files(Context) ].
    

%% @doc Check if there is a backup in progress.
backup_in_progress(Context) ->
    case gen_server:call(z_utils:name_for_host(?MODULE, z_context:site(Context)), in_progress_start) of
        undefined -> false;
        _ -> true
    end.


manage_schema(install, Context) ->
    m_backup_revision:install(Context).



%%====================================================================
%% API
%%====================================================================
%% @spec start_link(Args) -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
start_link(Args) when is_list(Args) ->
    Context = proplists:get_value(context, Args),
    Name = z_utils:name_for_host(?MODULE, z_context:site(Context)),
    gen_server:start_link({local, Name}, ?MODULE, Args, []).



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
    {ok, TimerRef} = timer:send_interval(?BCK_POLL_INTERVAL, periodic_backup),
    {ok, #state{
        context = z_context:new(Context),
        backup_pid = undefined,
        timer_ref = TimerRef
    }}.


%% @spec handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% @doc Start a backup
handle_call(start_backup, _From, State) ->
    case State#state.backup_pid of
        undefined ->
            %% @doc Return the base name of the dump files. The base name is composed of the date and time.
            %% @todo keep the backup page updated with the state of the current backup.
            Pid = do_backup(name(State#state.context), State),
            {reply, ok, State#state{backup_pid=Pid, backup_start=calendar:local_time()}};
        _Pid ->
            {reply, {error, in_progress}, State}
    end;

%% @doc Return the start datetime of the current running backup, if any.
handle_call(in_progress_start, _From, State) ->
    {reply, State#state.backup_start, State};

%% @doc Trap unknown calls
handle_call(Message, _From, State) ->
    {stop, {unknown_call, Message}, State}.


%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @doc Trap unknown casts
handle_cast(Message, State) ->
    {stop, {unknown_cast, Message}, State}.


%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% @doc Periodic check if a scheduled backup should start
handle_info(periodic_backup, #state{backup_pid=Pid} = State) when is_pid(Pid) ->
    z_utils:flush_message(periodic_backup),
    {noreply, State};
handle_info(periodic_backup, State) ->
    cleanup(State#state.context),
    z_utils:flush_message(periodic_backup), 
    case z_convert:to_bool(m_config:get_value(mod_backup, daily_dump, State#state.context)) of
        true -> maybe_daily_dump(State);
        false -> {noreply, State}
    end;

handle_info({'EXIT', Pid, normal}, State) ->
    case State#state.backup_pid of
        Pid ->
            %% @todo send an update to the page that started the backup
            {noreply, State#state{backup_pid=undefined, backup_start=undefined}};
        _ ->
            %% when connected to the page, then this might be the page exiting
            {noreply, State}
    end;

handle_info({'EXIT', Pid, _Error}, State) ->
    case State#state.backup_pid of
        Pid ->
            %% @todo send the error update to the page that started the backup
            %% @todo Log the error
            %% Remove all files of this backup
            Name = z_convert:to_list(erlydtl_dateformat:format(State#state.backup_start, "Ymd-His", State#state.context)),
            [ file:delete(F) || F <- filelib:wildcard(filename:join(dir(State#state.context), Name++"*")) ],
            {noreply, State#state{backup_pid=undefined, backup_start=undefined}};
        _ ->
            %% when connected to the page, then this might be the page exiting
            {noreply, State}
    end;

%% @doc Handling all non call/cast messages
handle_info(Info, State) ->
    ?DEBUG(Info),
    {noreply, State}.

%% @spec terminate(Reason, State) -> void()
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
terminate(_Reason, State) ->
    timer:cancel(State#state.timer_ref),
    ok.

%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @doc Convert process state when code is changed
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% support functions
%%====================================================================

%% @doc Keep the last 10 backups, delete all others.
cleanup(Context) ->
    Files = filelib:wildcard(filename:join(dir(Context), "*.sql")),
    Backups = lists:sort([ filename:rootname(F) || F <- Files ]),
    case length(Backups) of
        N when N > 10 ->
            ToDelete = lists:nthtail(10, lists:reverse(Backups)),
            [ file:delete(F++".sql") || F <- ToDelete ],
            [ file:delete(F++".tar.gz") || F <- ToDelete ],
            ok;
        _ ->
            nop
    end.
    


maybe_daily_dump(State) ->
    {Date, Time} = calendar:local_time(),
    case Time >= {3,0,0} andalso Time =< {7,0,0} of
        true ->
            DoStart = case list_backup_files(State#state.context) of
                [{_, LastBackupDate}|_] -> LastBackupDate < {Date, {0,0,0}};
                [] -> true
            end,
            case DoStart of
                true ->
                    Pid = do_backup(erlydtl_dateformat:format({Date, Time}, "Ymd-His", State#state.context), State),
                    {noreply, State#state{backup_pid=Pid, backup_start={Date, Time}}};
                false ->
                    {noreply, State}
            end;
        false ->
            {noreply, State}
    end.


%% @doc Start a backup and return the pid of the backup process, whilst linking to the process.
do_backup(Name, State) ->
    spawn_link(fun() -> do_backup_process(Name, State#state.context) end).


%% @todo Add a tar of all files in the files/archive directory (excluding preview)
do_backup_process(Name, Context) ->
    Cfg = check_configuration(),
    case proplists:get_value(ok, Cfg) of
        true ->
            ok = pg_dump(Name, Context),
            ok = archive(Name, Context);
        false ->
            {error, not_configured}
    end.


%% @doc Return and ensure the backup directory
dir(Context) ->
    z_path:files_subdir_ensure(backup, Context).

%% @doc Return the base name of the backup files.
name(Context) ->
    Now = calendar:local_time(),
    iolist_to_binary(
      [atom_to_list(z_context:site(Context)), "-",
       erlydtl_dateformat:format(Now, "Ymd-His", Context)]).


%% @doc Dump the sql database into the backup directory.  The Name is the basename of the dump.
pg_dump(Name, Context) ->
    {ok, Host} = pgsql_pool:get_database_opt(host, ?HOST(Context)),
    {ok, Port} = pgsql_pool:get_database_opt(port, ?HOST(Context)),
    {ok, User} = pgsql_pool:get_database_opt(username, ?HOST(Context)),
    {ok, Password} = pgsql_pool:get_database_opt(password, ?HOST(Context)),
    {ok, Database} = pgsql_pool:get_database_opt(database, ?HOST(Context)),
    {ok, Schema} = pgsql_pool:get_database_opt(schema, ?HOST(Context)),
    DumpFile = filename:join([dir(Context), z_convert:to_list(Name) ++ ".sql"]),
    PgPass = filename:join([dir(Context), ".pgpass"]),
    ok = file:write_file(PgPass, z_convert:to_list(Host)
                                ++":"++z_convert:to_list(Port)
                                ++":"++z_convert:to_list(Database)
                                ++":"++z_convert:to_list(User)
                                ++":"++z_convert:to_list(Password)),
    ok = file:change_mode(PgPass, 8#00600),
    Command = [
               "PGPASSFILE='",PgPass,"' '",
               db_dump_cmd(),
               "' -h ", Host,
               " -p ", z_convert:to_list(Port),
               " -w ", 
               " -f '", DumpFile, "' ",
               " -U '", User, "' ",
               case z_utils:is_empty(Schema) of
                   true -> [];
                   false -> [" -n '", Schema, "' "]
               end,
               Database],
    Result = case os:cmd(binary_to_list(iolist_to_binary(Command))) of
                 [] ->
                     ok;
                 _Output ->
                     ?zWarning(_Output, Context),
                     {error, _Output}
             end,
    ok = file:delete(PgPass),
    Result.


%% @doc Make a tar archive of all the files in the archive directory.
archive(Name, Context) ->
    ArchiveDir = z_path:media_archive(Context),
    case filelib:is_dir(ArchiveDir) of
        true ->
            DumpFile = filename:join(dir(Context), z_convert:to_list(Name) ++ ".tar.gz"),
            Command = lists:flatten([
                                     archive_cmd(),
                                     " -c -z ",
                                     "-f '", DumpFile, "' ",
                                     "-C '", ArchiveDir, "' ",
                                     " ."]),
            [] = os:cmd(Command),
            ok;
        false ->
            %% No files uploaded
            ok
    end.


%% @doc List all backups in the backup directory.
list_backup_files(Context) ->
    Files = filelib:wildcard(filename:join(dir(Context), "*.sql")),
    lists:reverse(lists:sort([ {filename:rootname(filename:basename(F), ".sql"), filename_to_date(F)} || F <- Files ])).

filename_to_date(File) ->
    R = re:run(filename:basename(File), "([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})", [{capture, all, list}]),
    {match, [_, YY, MM, DD, HH, II, SS]} = R,
    Y = list_to_integer(YY),
    M = list_to_integer(MM),
    D = list_to_integer(DD),
    H = list_to_integer(HH),
    I = list_to_integer(II),
    S = list_to_integer(SS),
    {{Y,M,D},{H,I,S}}.


archive_cmd() ->
    z_convert:to_list(z_config:get(tar, "tar")).

db_dump_cmd() ->
    z_convert:to_list(z_config:get(pg_dump, "pg_dump")).


%% @doc Check if we can make backups, the configuration is ok
check_configuration() ->
    Which = fun(Cmd) -> filelib:is_regular(z_string:trim_right(os:cmd("which " ++ z_utils:os_escape(Cmd)))) end,
    Db = Which(db_dump_cmd()),
    Tar = Which(archive_cmd()),
    [{ok, Db and Tar},
     {db_dump, Db},
     {archive, Tar}].

