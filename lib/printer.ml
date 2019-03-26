(*   Copyright 2018 Julian Nagele and Maria A Schett

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)

open Core
open Program
open Evmenc
open Z3util

type step = {input: Program.t; opt: Program.t; optimal: bool; tval: bool option}

let show_ebso_snippet s =
  let ea = mk_enc_consts s `All in
  [ Program.show_hex s
  ; Program.show_h s
  ; [%show: int] (List.length s)
  ; [%show: int] (List.length ea.xs)
  ; [%show: int] (List.length (List.concat (Map.data ea.uis)))
  ; [%show: int] (List.length ea.ss)
  ]

let create_ebso_snippets bbs =
  [ "byte code"
  ; "op code"
  ; "instruction count"
  ; "stack depth"
  ; "uninterpreted count"
  ; "storage access count"
  ] ::
  List.filter_map bbs ~f:(fun bb -> ebso_snippet bb |> Option.map ~f:(show_ebso_snippet))

let show_step step =
  let g = (total_gas_cost step.input - total_gas_cost step.opt) in
  String.concat
    [ "Optimized\n"
    ;  Program.show step.input
    ; "to\n"
    ; Program.show step.opt
    ; "Saved "
    ; [%show: int] g
    ; " gas"
    ; if Option.is_some step.tval then ", translation validation "
      ^ (if Option.value_exn step.tval then "successful" else "failed")
      else ""
    ; if step.optimal then ", this instruction sequence is optimal" else ""
    ; "."
    ]

let print_step step pi =
  if pi || step.optimal then
      Out_channel.printf "%s" (show_step step)
  else ()

let show_result step =
  let g = (total_gas_cost step.input - total_gas_cost step.opt) in
  [ show_hex step.input
  ; show_hex step.opt
  ; [%show: int] g
  ; [%show: bool] step.optimal]
  @ Option.to_list (Option.map step.tval ~f:Bool.to_string) @
  [ [%show: int] (List.length step.input)
  ; [%show: int] (List.length step.opt)]

let create_result steps =
  [ "source"
  ; "target"
  ; "gas saved"
  ; "known optimal"
  ; "translation validation"
  ; "source instruction count"
  ; "target instruction count"
  ] ::
  List.rev_map ~f:show_result steps

let show_model m = String.concat [ "Model found:\n"; Z3.Model.to_string m; "\n"]

let log_model m lm =
  let s = match m with Some m -> (show_model m) | None -> "" in
  if lm then Out_channel.prerr_endline s else ()

let show_constraint c =
  String.concat
    [ "Constraint generated:\n"
    ; Z3.Expr.to_string (Z3.Expr.simplify c None)
    ; "\n"
    ]

let log_constraint c lc =
  if lc then Out_channel.prerr_endline (show_constraint c) else ()

let show_smt_benchmark c =
  String.concat
    [ "SMT-LIB Benchmark generated:\n"
     ; Z3.SMT.benchmark_to_smtstring !ctxt "" "" "unknown" "" [] (Z3.Expr.simplify c None)
    ]

let log_benchmark b lb =
  if lb then Out_channel.prerr_endline (show_smt_benchmark b) else ()