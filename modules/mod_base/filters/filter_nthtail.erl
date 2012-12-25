%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2010 Marc Worrell
%% @doc 'nthtail' filter, return nth tail of a list

%% Copyright 2010 Marc Worrell
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

-module(filter_nthtail).
-export([nthtail/3]).


nthtail(In, N, Context) ->
    case erlydtl_runtime:to_list(In, Context) of
        L when is_list(L) ->
            try
                lists:nthtail(z_convert:to_integer(N), L)
            catch 
                _:_ -> []
            end;
        _ -> 
            []
    end.

