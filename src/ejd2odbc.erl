%%%----------------------------------------------------------------------
%%% File    : ejd2odbc.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Export some mnesia tables to SQL DB
%%% Created : 22 Aug 2005 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejd2odbc).

-author('alexey@process-one.net').

-include("logger.hrl").

-export([export/2, export/3, import/2, import/3, import_info/0]).

-record(sql_dump, {fd, type}).

-define(MAX_RECORDS_PER_TRANSACTION, 100).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
%%% How to use:
%%% A table can be converted from Mnesia to an ODBC database by calling
%%% one of the API function with the following parameters:
%%% - Server is the server domain you want to convert
%%% - Output can be either odbc to export to the configured relational
%%%   database or "Filename" to export to text file.

modules() ->
    [ejabberd_auth,
     mod_announce,
     mod_caps,
     mod_irc,
     mod_last,
     mod_muc,
     mod_offline,
     mod_privacy,
     mod_private,
     mod_roster,
     mod_shared_roster,
     mod_vcard,
     mod_vcard_xupdate].

export(Server, Output) ->
    LServer = jlib:nameprep(iolist_to_binary(Server)),
    Modules = modules(),
    IO = prepare_output(Output),
    lists:foreach(
      fun(Module) ->
              export(LServer, IO, Module)
      end, Modules),
    close_output(Output, IO).

export(Server, Output, Module) ->
    LServer = jlib:nameprep(iolist_to_binary(Server)),
    IO = prepare_output(Output),
    lists:foreach(
      fun({Table, ConvertFun}) ->
              export(LServer, Table, IO, ConvertFun)
      end, Module:export(Server)),
    close_output(Output, IO).

import(Server, Dir) ->
    lists:foreach(
      fun(Mod) ->
              import(Server, Dir, Mod)
      end, modules()).

import(Server, Dir, Mod) ->
    LServer = jlib:nameprep(iolist_to_binary(Server)),
    lists:foreach(
      fun({File, Tab, _Mod, FieldsNumber}) ->
              FileName = filename:join([Dir, File]),
              case open_sql_dump(FileName) of
                  {ok, Dump} ->
                      DBType = db_type(LServer, Mod),
                      catch (Mod:import_start(LServer, DBType)),
                      import_rows(LServer, DBType, Tab, Mod, Dump, FieldsNumber),
                      catch (Mod:import_end(LServer, DBType)),
                      close_sql_dump(Dump);
                  {error, enoent} ->
                      ok;
                  eof ->
                      ?INFO_MSG("It seems like SQL dump ~s is empty", [FileName]);
                  Err ->
                      ?ERROR_MSG("Failed to open SQL dump ~s: ~s",
                                 [FileName, format_error(Err)])
              end
      end, Mod:import_info()).

import_info() ->
    lists:flatmap(
      fun(Mod) ->
              Info = Mod:import_info(),
              lists:map(
                fun({Tab, FieldsNum}) ->
                        FileName = <<Tab/binary, ".txt">>,
                        {FileName, Tab, Mod, FieldsNum}
                end, Info)
      end, modules()).

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
export(LServer, Table, IO, ConvertFun) ->
    F = fun () ->
                mnesia:read_lock_table(Table),
                {_N, SQLs} =
                    mnesia:foldl(
                      fun(R, {N, SQLs} = Acc) ->
                              case ConvertFun(LServer, R) of
                                  [] ->
                                      Acc;
                                  SQL ->
                                      if N < (?MAX_RECORDS_PER_TRANSACTION) - 1 ->
                                              {N + 1, [SQL | SQLs]};
                                         true ->
                                              output(LServer,
                                                     Table, IO,
                                                     flatten([SQL | SQLs])),
                                              {0, []}
                                      end
                              end
                      end,
                      {0, []}, Table),
                output(LServer, Table, IO, flatten(SQLs))
        end,
    mnesia:transaction(F).

output(_LServer, _Table, _IO, []) ->
    ok;
output(LServer, _Table, odbc, SQLs) ->
    ejabberd_odbc:sql_transaction(LServer, SQLs);
output(_LServer, Table, Fd, SQLs) ->
    file:write(Fd, ["-- \n-- Mnesia table: ", atom_to_list(Table),
                    "\n--\n", SQLs]).

prepare_output(FileName) ->
    prepare_output(FileName, normal).

prepare_output(FileName, Type) when is_binary(FileName) ->
    prepare_output(binary_to_list(FileName), Type);
prepare_output(FileName, normal) when is_list(FileName) ->
    case file:open(FileName, [write, raw]) of
        {ok, Fd} ->
            Fd;
        Err ->
            exit(Err)
    end;
prepare_output(Output, _Type) ->
    Output.

close_output(FileName, Fd) when FileName /= Fd ->
    file:close(Fd),
    ok;
close_output(_, _) ->
    ok.

flatten(SQLs) ->
    flatten(SQLs, []).

flatten([L|Ls], Acc) ->
    flatten(Ls, flatten1(lists:reverse(L), Acc));
flatten([], Acc) ->
    Acc.

flatten1([H|T], Acc) ->
    flatten1(T, [[H, $\n]|Acc]);
flatten1([], Acc) ->
    Acc.

db_type(LServer, ejabberd_auth) ->
    case ejabberd_auth:auth_modules(LServer) of
        [ejabberd_auth_riak|_] -> riak;
        [ejabberd_auth_p1db|_] -> p1db;
        [ejabberd_auth_odbc|_] -> odbc;
        _ -> mnesia
    end;
db_type(LServer, Mod) ->
    gen_mod:db_type(LServer, Mod).

import_rows(LServer, DBType, Tab, Mod, Dump, FieldsNumber) ->
    case read_row_from_sql_dump(Dump, FieldsNumber) of
        {ok, Fields} ->
            Mod:import(LServer, DBType, Tab, Fields),
            import_rows(LServer, DBType, Tab, Mod, Dump, FieldsNumber);
        eof ->
            ok;
        Err ->
            ?ERROR_MSG("Failed to read row from SQL dump: ~s",
                       [format_error(Err)])
    end.

open_sql_dump(FileName) ->
    case file:open(FileName, [raw, read, binary, read_ahead]) of
        {ok, Fd} ->
            case file:read(Fd, 11) of
                {ok, <<"PGCOPY\n", 16#ff, "\r\n", 0>>} ->
                    case skip_pgcopy_header(Fd) of
                        ok ->
                            {ok, #sql_dump{fd = Fd, type = pgsql}};
                        Err ->
                            Err
                    end;
                {ok, _} ->
                    file:position(Fd, 0),
                    {ok, #sql_dump{fd = Fd, type = mysql}};
                Err ->
                    Err
            end;
        Err ->
            Err
    end.

close_sql_dump(#sql_dump{fd = Fd}) ->
    file:close(Fd).

read_row_from_sql_dump(#sql_dump{fd = Fd, type = pgsql}, _) ->
    case file:read(Fd, 2) of
        {ok, <<(-1):16/signed>>} ->
            eof;
        {ok, <<FieldsNum:16>>} ->
            read_fields(Fd, FieldsNum, []);
        {ok, _} ->
            {error, eof};
        eof ->
            {error, eof};
        {error, _} = Err ->
            Err
    end;
read_row_from_sql_dump(#sql_dump{fd = Fd, type = mysql}, FieldsNum) ->
    read_lines(Fd, FieldsNum, <<"">>, []).

skip_pgcopy_header(Fd) ->
    try
        {ok, <<_:4/binary, ExtSize:32>>} = file:read(Fd, 8),
        {ok, <<_:ExtSize/binary>>} = file:read(Fd, ExtSize),
        ok
    catch error:{badmatch, {error, _} = Err} ->
            Err;
          error:{badmatch, _} ->
            {error, eof}
    end.

read_fields(_Fd, 0, Acc) ->
    {ok, lists:reverse(Acc)};
read_fields(Fd, N, Acc) ->
    case file:read(Fd, 4) of
        {ok, <<(-1):32/signed>>} ->
            read_fields(Fd, N-1, [null|Acc]);
        {ok, <<ValSize:32>>} ->
            case file:read(Fd, ValSize) of
                {ok, <<Val:ValSize/binary>>} ->
                    read_fields(Fd, N-1, [Val|Acc]);
                {ok, _} ->
                    {error, eof};
                Err ->
                    Err
            end;
        {ok, _} ->
            {error, eof};
        eof ->
            {error, eof};
        {error, _} = Err ->
            Err
    end.

read_lines(_Fd, 0, <<"">>, Acc) ->
    {ok, lists:reverse(Acc)};
read_lines(Fd, N, Buf, Acc) ->
    case file:read_line(Fd) of
        {ok, Data} when size(Data) >= 2 ->
            Size = size(Data) - 2,
            case Data of
                <<Val:Size/binary, 0, $\n>> ->
                    NewBuf = <<Buf/binary, Val/binary>>,
                    read_lines(Fd, N-1, <<"">>, [NewBuf|Acc]);
                _ ->
                    NewBuf = <<Buf/binary, Data/binary>>,
                    read_lines(Fd, N, NewBuf, Acc)
            end;
        {ok, Data} ->
            NewBuf = <<Buf/binary, Data/binary>>,
            read_lines(Fd, N, NewBuf, Acc);
        eof when Buf == <<"">>, Acc == [] ->
            eof;
        eof ->
            {error, eof};
        {error, _} = Err ->
            Err
    end.

format_error({error, eof}) ->
    "unexpected end of file";
format_error({error, Posix}) ->
    file:format_error(Posix).
