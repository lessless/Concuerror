%% -*- erlang-indent-level: 2 -*-

-module(concuerror_options).

-export([parse_cl/1, filter_options/2, finalize/1]).

-include("concuerror.hrl").

-spec parse_cl([string()]) -> options().

parse_cl(CommandLineArgs) ->
  try
    parse_cl_aux(CommandLineArgs)
  catch
    throw:opt_error -> {exit, error}
  end.

parse_cl_aux(CommandLineArgs) ->
  case getopt:parse(getopt_spec(), CommandLineArgs) of
    {ok, {Options, OtherArgs}} ->
      case {proplists:get_bool(help, Options),
            proplists:get_bool(version, Options)} of
        {true,_} ->
          cl_usage(),
          {exit, ok};
        {_,true} ->
          cl_version(),
          {exit, ok};
        {false, false} ->
          case OtherArgs =:= [] of
            true -> ok;
            false -> opt_warn("Ignoring: ~s", [string:join(OtherArgs, " ")])
          end,
          Options
      end;
    {error, Error} ->
      case Error of
        {missing_option_arg, Option} ->
          opt_error("no argument given for --~s", [Option]);
        _Other ->
          opt_error(getopt:format_error([], Error))
      end
  end.

getopt_spec() ->
  %% We are storing additional info in the options spec. Filter these before
  %% running getopt.
  [{Name, Short, Long, Type, Help} ||
    {Name, _Classes, Short, Long, Type, Help} <- options()].

options() ->
  [{module, [frontend], $m, "module", atom,
    "The module containing the main test function."}
  ,{test, [frontend], $t, "test", {atom, test},
    "The name of the 0-arity function that starts the test."}
  ,{output, [logger], $o, "output", {string, "results.txt"},
    "Output file."}
  ,{symbolic, [logger], $s, "symbolic", {boolean, false},
    "Use symbolic names for process identifiers."}
  ,{patha, [frontend, logger], undefined, "pa", string,
    "Add directory to the front of the code path."}
  ,{pathz, [frontend, logger], undefined, "pz", string,
    "Add directory to the end of the code path."}
  ,{file, [frontend], $f, "file", string,
    "Load a specific file (.beam or .erl). (A .erl file should not require"
    " any command line compile options.)"}
  ,{help, [frontend], $h, "help", undefined,
    "Display this information."}
  ,{quiet, [frontend], $q, "quiet", undefined,
    "Do not write anything to standard output. Equivalent to --verbose 0."}
  ,{verbose, [logger], $v, "verbose", integer,
    io_lib:format("Sets the verbosity level (0-~p) [default: ~p].",
                  [?MAX_VERBOSITY, ?DEFAULT_VERBOSITY])}
  ,{assume_racing, [logger, scheduler], undefined, "assume_racing", {boolean, true},
    "If there is no info about whether a specific pair of built-ins may race,"
    " assume that they do indeed race. Set this to false to detect missing"
    " dependency info."}
  ,{after_timeout, [logger, process], $a, "after", {integer, infinite},
    "Assume that 'after' clause timeouts higher or equal to the specified value"
    " will never be triggered."} %% XXX, unless no other process can progress."}
  ,{normal_exit, [logger, scheduler], undefined, "treat_as_normal", {atom, normal},
    "Specify exit reasons that are considered 'normal' and not reported as"
    " crashes. Useful e.g. when analyzing supervisors ('shutdown' is probably"
    " also a normal reason in this case)."}
  ,{report_unknown, [logger, process], undefined, "report_unknown",
    {boolean, false},
    "Report built-ins that are not explicitly classified by Concuerror as"
    " racing or race-free. (Concuerror expects such built-ins to always return"
    " the same result otherwise"}
  %% ,{bound, [logger, scheduler], $b, "bound", {integer, -1},
  %%   "Preemption bound (-1 for infinite)."}
  %% ,{distributed, [logger, scheduler], $d, "distributed", {boolean, true},
  %%   "Use distributed Erlang semantics: messages are not delivered immediately"
  %%   " after being sent."}
  %% ,{'light-dpor', [logger, scheduler], $l, "light-dpor", {boolean, false},
  %%   "Use lightweight (source) DPOR instead of optimal."}
  ,{version, [frontend], undefined, "version", undefined,
    "Display version information about Concuerror."}
  ,{wait, [logger, scheduler], $w, "wait", {integer, ?MINIMUM_TIMEOUT},
    "How many ms to wait before assuming a process to be stuck in an infinite"
    " loop between two operations with side-effects. Setting it to -1 makes"
    " Concuerror wait indefinitely. Otherwise must be >= " ++
      integer_to_list(?MINIMUM_TIMEOUT) ++ "."}
   %% These options won't make it to the getopt script
  ,{target, [logger, scheduler]} %% Generated from module and test or given explicitlyq
  ,{halt, []}                    %% Controlling whether a halt will happen
  ,{files, [logger]}             %% List of included files (to be shown in the log)
  ,{modules, [logger, process]}  %% List of included files (to be shown in the log)
  ,{processes, [logger, process]}
  ,{logger, [process]}
  ,{frontend, []}
  ].

-spec filter_options(atom(), {atom(), term()}) -> boolean().

filter_options(Mode, {Key, _}) ->
  OptInfo = lists:keyfind(Key, 1, options()),
  lists:member(Mode, element(2, OptInfo)).

cl_usage() ->
  getopt:usage(getopt_spec(), "./concuerror").

cl_version() ->
  io:format(standard_error, "Concuerror v~s~n",[?VSN]),
  ok.

-spec finalize(options()) -> options().

finalize(Options) ->
  case code:is_sticky(ets) of
    true ->
      opt_error("Concuerror must be able to reload sticky modules."
                " Use the command-line script or start Erlang with -nostick.");
    false ->
      Modules = [{modules, ets:new(modules, [public])}],
      Finalized = finalize(lists:reverse(proplists:unfold(Options),Modules), []),
      case proplists:get_value(target, Finalized, undefined) of
        {M,F,B} when is_atom(M), is_atom(F), is_list(B) ->
          case  proplists:is_defined(verbose, Finalized) of
            true -> Finalized;
            false -> [{verbose, ?DEFAULT_VERBOSITY}|Finalized]
          end;
        _ ->
          opt_error("The module containing the main test function has not been"
                    " specified.")
      end
  end.

finalize([], Acc) -> Acc;
finalize([{quiet, true}|Rest], Acc) ->
  NewRest = proplists:delete(verbose, proplists:delete(quiet, Rest)),
  finalize(NewRest, [{verbose, 0}|Acc]);
finalize([{normal_exit, N}|Rest], Acc) ->
  Normals = [normal,N|proplists:get_all_values(normal_exit, Rest)],
  NewRest = proplists:delete(normal_exit, Rest),
  finalize(NewRest, [{normal_exit, lists:usort(Normals)}|Acc]);
finalize([{verbose, N}|Rest], Acc) ->
  case proplists:is_defined(quiet, Rest) =:= true andalso N =/= 0 of
    true ->
      opt_error("--verbose defined after --quiet");
    false ->
      Sum = lists:sum([N|proplists:get_all_values(verbose, Rest)]),
      Verbosity = min(Sum, ?MAX_VERBOSITY),
      NewRest = proplists:delete(verbose, Rest),
      finalize(NewRest, [{verbose, Verbosity}|Acc])
  end;
finalize([{Key, Value}|Rest], Acc)
  when Key =:= file; Key =:= patha; Key =:=pathz ->
  case Key of
    file ->
      Modules = proplists:get_value(modules, Rest),
      Files = [Value|proplists:get_all_values(file, Rest)],
      {LoadedFiles, MoreOptions} = compile_and_load(Files, Modules),
      NewRest = proplists:delete(file, Rest),
      finalize(MoreOptions ++ NewRest, [{files, LoadedFiles}|Acc]);
    Else ->
      PathAdd =
        case Else of
          patha -> fun code:add_patha/1;
          pathz -> fun code:add_pathz/1
        end,
      case PathAdd(Value) of
        true -> ok;
        {error, bad_directory} ->
          opt_error("could not add ~s to code path", [Value])
      end,
      finalize(Rest, Acc)
  end;
finalize([{Key, Value}|Rest], Acc) ->
  case proplists:is_defined(Key, Rest) of
    true ->
      opt_error("multiple instances of --~s defined", [Key]);
    false ->
      case Key of
        module ->
          case proplists:get_value(test, Rest, 1) of
            Name when is_atom(Name) ->
              NewRest = proplists:delete(test, Rest),
              finalize(NewRest, [{target, {Value, Name, []}}|Acc]);
            _ -> opt_error("The name of the test function is missing")
          end;
        output ->
          case file:open(Value, [write]) of
            {ok, IoDevice} ->
              finalize(Rest, [{Key, {IoDevice, Value}}|Acc]);
            {error, _} ->
              opt_error("could not open file ~s for writing", [Value])
          end;
        wait ->
          case Value of
            -1 ->
              finalize(Rest, [{Key, infinite}|Acc]);
            N when is_integer(N), N >= ?MINIMUM_TIMEOUT ->
              finalize(Rest, [{Key, N}|Acc]);
            _Else ->
              opt_error("--~s value must be -1 (infinite) or >= "
                       ++ integer_to_list(?MINIMUM_TIMEOUT), [Key])
          end;
        test ->
          case Rest =:= [] of
            true -> finalize(Rest, Acc);
            false -> finalize(Rest ++ [{Key, Value}], Acc)
          end;
        _ ->
          finalize(Rest, [{Key, Value}|Acc])
      end
  end.

compile_and_load(Files, Modules) ->
  compile_and_load(Files, Modules, {[],[]}).

compile_and_load([], _Modules, {Acc, MoreOpts}) ->
  {lists:sort(Acc), MoreOpts};
compile_and_load([File|Rest], Modules, {Acc, MoreOpts}) ->
  case filename:extension(File) of
    ".erl" ->
      case compile:file(File, [binary, debug_info, report_errors]) of
        {ok, Module, Binary} ->
          Default = code:which(Module),
          case Default =:= non_existing of
            true -> ok;
            false ->
              opt_warn("file ~s shadows the default ~s", [File, Default])
          end,
          ok = concuerror_loader:load_binary(Module, File, Binary, Modules),
          NewMoreOpts = try Module:concuerror_options() catch _:_ -> [] end,
          compile_and_load(Rest, Modules, {[File|Acc], NewMoreOpts++MoreOpts});
        error ->
          Format = "could not compile ~s (try to add the .beam file instead)",
          opt_error(Format, [File])
      end;
    ".beam" ->
      case beam_lib:chunks(File, []) of
        {ok, {Module, []}} ->
          ok = concuerror_loader:load_binary(Module, File, File, Modules),
          NewMoreOpts = try Module:concuerror_options() catch _:_ -> [] end,
          compile_and_load(Rest, Modules, {[File|Acc], NewMoreOpts++MoreOpts});
        Else ->
          opt_error(beam_lib:format_error(Else))
      end;
    _Other ->
      opt_error("~s is not a .erl or .beam file", [File])
  end.

-spec opt_error(string()) -> no_return().

opt_error(Format) ->
  opt_error(Format, []).

opt_error(Format, Data) ->
  io:format(standard_error, "concuerror: ERROR: " ++ Format ++ "~n", Data),
  io:format(standard_error, "concuerror: Use --help for more information.\n", []),
  throw(opt_error).

opt_warn(Format, Data) ->
  io:format(standard_error, "concuerror: WARNING: " ++ Format ++ "~n", Data),
  ok.
