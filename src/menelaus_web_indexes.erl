%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(menelaus_web_indexes).

-include("ns_common.hrl").
-export([handle_settings_get/1, handle_settings_post/1, handle_index_status/1]).

-import(menelaus_util,
        [reply/2,
         reply_json/2,
         validate_any_value/3,
         validate_by_fun/3,
         validate_has_params/1,
         validate_unsupported_params/1,
         validate_integer/2,
         validate_range/4,
         execute_if_validated/3]).

handle_settings_get(Req) ->
    menelaus_web:assert_is_40(),

    Settings = get_settings(),
    true = (Settings =/= undefined),
    reply_json(Req, {Settings}).

get_settings() ->
    S0 = index_settings_manager:get(generalSettings),
    case cluster_compat_mode:is_cluster_45() of
        true ->
            [{storageMode, index_settings_manager:get(storageMode)}] ++ S0;
        false ->
            S0
    end.

validate_settings_post(Args) ->
    R0 = validate_has_params({Args, [], []}),
    R1 = lists:foldl(
           fun ({Key, Min, Max}, Acc) ->
                   Acc1 = validate_integer(Key, Acc),
                   validate_range(Key, Min, Max, Acc1)
           end, R0, integer_settings()),
    R2 = validate_string(R1, logLevel),
    R3 = case cluster_compat_mode:is_cluster_45() of
             true ->
                 validate_storage_mode(R2);
             false ->
                 R2
         end,

    validate_unsupported_params(R3).

validate_storage_mode(State) ->
    %% Note, at the beginning the storage mode will be empty. Once set,
    %% validate_string will prevent user from changing it back to empty
    %% since it is not one of the acceptable values.
    State1 = validate_string(State, storageMode),

    %% Do not allow:
    %% - changing index storage mode to mem optimized in community edition
    %% - changing index storage mode when there are nodes running index
    %% service in the cluster
    IndexErr = "Changing the optimization mode of global indexes is not supported when index service nodes are present in the cluster. Please remove all index service nodes to change this option.",
    CEErr = "Memory optimized indexes are restricted to enterprise edition and are not available in the community edition.",

    validate_by_fun(
      fun (Value) ->
              OldValue = index_settings_manager:get(storageMode),
              IsEE = cluster_compat_mode:is_enterprise(),
              IsMemOpt = index_settings_manager:is_memory_optimized(Value),
              case OldValue =:= <<"">> orelse Value =:= OldValue of
                  true ->
                        case IsMemOpt andalso IsEE =:= false of
                            true ->
                              ?log_debug("Community edition. Cannot set index storage mode to memory optimized. ~n"),
                              {error, CEErr};
                            false ->
                                ok
                        end;
                  false ->
                      case IsEE of
                          true ->
                              %% Note it is not sufficient to check
                              %% service_active_nodes(index) because the
                              %% index nodes could be down or failed over.
                              IndexNodes = ns_cluster_membership:service_nodes(ns_node_disco:nodes_wanted(), index),
                              case IndexNodes of
                                  [] ->
                                      ok;
                                  _ ->
                                      ?log_debug("Index nodes ~p present. Cannot change index storage mode. ~n", [IndexNodes]),
                                      {error, IndexErr}
                              end;
                          false ->
                              ?log_debug("Community edition. Cannot change index storage mode. ~n"),
                              {error, CEErr}
                      end
              end
      end, storageMode, State1).

acceptable_values(logLevel) ->
    ["silent", "fatal", "error", "warn", "info",
     "verbose", "timing", "debug", "trace"];
acceptable_values(storageMode) ->
    ["forestdb", "memory_optimized"].

validate_string(State, Param) ->
    State1 = validate_any_value(Param, State, fun list_to_binary/1),
    validate_by_fun(
      fun (Value) ->
              AV = acceptable_values(Param),
              case lists:member(binary_to_list(Value), AV) of
                  true ->
                      ok;
                  false ->
                      {error,
                       io_lib:format("~p must be one of ~s",
                                     [Param, string:join(AV, ", ")])}
              end
      end, Param, State1).

update_storage_mode(Req, Values) ->
    case proplists:get_value(storageMode, Values) of
        undefined ->
            Values;
        StorageMode ->
            ok = update_settings(storageMode, StorageMode),
            ns_audit:modify_index_storage_mode(Req, StorageMode),
            proplists:delete(storageMode, Values)
    end.
update_settings(Key, Value) ->
    case index_settings_manager:update(Key, Value) of
        {ok, _} ->
            ok;
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

handle_settings_post(Req) ->
    menelaus_web:assert_is_40(),

    execute_if_validated(
      fun (Values) ->
              Values1 = case cluster_compat_mode:is_cluster_45() of
                            true ->
                                update_storage_mode(Req, Values);
                            false ->
                                Values
                        end,
              case Values1 of
                  [] ->
                      ok;
                  _ ->
                      ok = update_settings(generalSettings, Values1)
              end,
              reply_json(Req, {get_settings()})
      end, Req, validate_settings_post(Req:parse_post())).

integer_settings() ->
    NearInfinity = 1 bsl 64 - 1,
    [{indexerThreads, 0, 1024},
     {memorySnapshotInterval, 1, NearInfinity},
     {stableSnapshotInterval, 1, NearInfinity},
     {maxRollbackPoints, 1, NearInfinity}].

handle_index_status(Req) ->
    menelaus_web:assert_is_40(),
    {ok, Indexes0, Stale, Version} = indexer_gsi:get_indexes(),
    Indexes = [{Props} || Props <- Indexes0],

    Warnings =
        case Stale of
            true ->
                Msg = <<"Cannot communicate with indexer process. "
                        "Information on indexes may be stale. Will retry.">>,
                [Msg];
            false ->
                []
        end,

    reply_json(Req, {[{indexes, Indexes},
                      {version, Version},
                      {warnings, Warnings}]}).
