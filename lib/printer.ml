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

let mk_step input opt optimal tval =
  { input = Program.const_to_val input
  ; opt = Program.const_to_val opt
  ; optimal = optimal
  ; tval = tval
  }

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
  [ "source bytecode"
  ; "source opcode"
  ; "source instruction count"
  ; "stack depth"
  ; "uninterpreted count"
  ; "storage access count"
  ] ::
  List.filter_map bbs ~f:(fun bb -> ebso_snippet bb |> Option.map ~f:(show_ebso_snippet))

let show_step step =
  let g = (GC.to_int (total_gas_cost step.input) - GC.to_int (total_gas_cost step.opt)) in
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
    ; ".\n"
    ]

let print_step step pi =
  if pi || step.optimal then
      Out_channel.printf "%s" (show_step step)
  else ()

let show_gas step =
  if List.mem (step.input @ step.opt) SSTORE ~equal:Instruction.equal then
    ["tbc" ; "tbc"; "tbc"]
  else
    let gas_source = total_gas_cost step.input
    and gas_target = total_gas_cost step.opt in
    [ [%show: GC.t] gas_source
    ; [%show: GC.t] gas_target
    ; [%show: int] (GC.to_int gas_source - GC.to_int gas_target) ]

let show_result step =
  [ show_hex step.input
  ; show_hex step.opt
  ; show_h step.opt
  ; [%show: int] (List.length step.opt)
  ]
  @ show_gas step @
  [ [%show: bool] step.optimal]
  @ Option.to_list (Option.map step.tval ~f:Bool.to_string)


let create_result steps =
  [ "source bytecode"
  ; "target bytecode"
  ; "target opcode"
  ; "target instruction count"
  ; "source gas"
  ; "target gas"
  ; "gas saved"
  ; "known optimal"
  ; "translation validation"
  ] ::
  List.rev_map ~f:show_result steps

let show_model m = String.concat [ "Model found:\n"; Z3.Model.to_string m; "\n"]

let log_model m lm =
  let s = match m with Some m -> (show_model m) | None -> "" in
  if lm then Out_channel.prerr_endline s else ()

let show_smt_benchmark c =
  String.concat
    [ "SMT-LIB Benchmark generated:\n"
     ; Z3.SMT.benchmark_to_smtstring !ctxt "" "" "unknown" "" [] (Z3.Expr.simplify c None)
    ]

let log_benchmark b lb =
  if lb then Out_channel.prerr_endline (show_smt_benchmark b) else ()
