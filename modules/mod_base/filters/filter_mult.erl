%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2010 Marc Worrell
%% @doc 'mult' filter, multiply a number with a value

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

-module(filter_mult).
-export([mult/3]).

mult(undefined, _Number, _Context) ->
    undefined;
mult(Input, Number, Context) when is_binary(Input) ->
    z_convert:to_binary(mult(binary_to_list(Input), Number, Context));
mult(Input, Number, Context) when is_list(Input) ->
    z_convert:to_list(mult(list_to_integer(Input), Number, Context));
mult(Input, Number, _Context) when is_integer(Input) ->
    case z_convert:to_integer(Number) of
        undefined -> undefined;
        N -> Input * N
    end;
mult(Input, Number, _Context) when is_float(Input) ->
    case z_convert:to_float(Number) of
        undefined -> undefined;
        N -> Input * N
    end.
