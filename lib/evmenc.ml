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
open Z3util
open Instruction
open Program
open Enc_consts
open Evm_state

module PC = Program_counter
module GC = Gas_cost
module SI = Stack_index

let init_rom ea st i rom =
  let open Z3Ops in
  let d = arity i in
  let js = poss_of_instr ea.p i in
  let us = Map.find_exn ea.uis i in
  let ajs = List.map js ~f:(fun j -> Evm_stack.enc_top_d st.stack (PC.enc j) d) in
  let w_dflt = Word.enc_int 0 in
  let ws = List.init d ~f:(fun l -> Word.const ("w" ^ [%show: int] l)) in
  foralls ws (
    (rom @@ (forall_vars ea @ ws)) ==
      List.fold_right (List.zip_exn ajs us) ~init:w_dflt
        ~f:(fun (aj, uj) enc -> ite (conj (List.map2_exn aj ws ~f:(==))) uj enc)
  )

let init_storage ea st =
  let open Z3Ops in
  let js = poss_of_instr ea.p SLOAD @ poss_of_instr ea.p SSTORE in
  let ks = List.concat_map js ~f:(fun j -> Evm_stack.enc_top_d st.stack (PC.enc j) 1) in
  let w_dflt = Word.enc_int 0 in
  let w = Word.const "w" in
  forall w (
    (st.storage @@ (forall_vars ea @ [PC.init; w]) ==
     List.fold_right (List.zip_exn ks ea.ss) ~init:w_dflt
       ~f:(fun (k, s) enc -> ite (w == k) s enc)))

let init ea st =
  let open Z3Ops in
  (* careful: if stack_depth is larger than 2^sas, no checks *)
  Evm_stack.init st.stack (stack_depth ea.p) ea.xs
  && (st.exc_halt @@ [PC.init] == btm)
  && (st.used_gas @@ (forall_vars ea @ [PC.init]) == GC.enc GC.zero)
  && init_storage ea st
  && Map.fold ea.roms ~init:top ~f:(fun ~key:i ~data:f e -> e && init_rom ea st i f)

let enc_const_uninterpreted ea st j i =
  let name = Instruction.unint_name 0 i in
  Evm_stack.enc_push ea.a st j (Pusharg.Word (Const name))

let enc_nonconst_uninterpreted ea sk j i =
  let rom = Map.find_exn ea.roms i in
  let open Z3Ops in let open Evm_stack in
  let sc'= sk.ctr @@ [j + one] in
  let ajs = Evm_stack.enc_top_d sk j (arity i) in
  (sk.el (j + one) (sc' - SI.enc 1)) == (rom @@ ((forall_vars ea) @ ajs))

let enc_sload ea st j =
  Evm_stack.enc_unaryop st.stack j (fun w -> (st.storage <@@> (forall_vars ea) @ [j; w]))

let enc_sstore ea sk str j =
  let open Z3Ops in let open Evm_stack in
  let sc = sk.ctr @@ [j] in
  let strg w = str @@ (forall_vars ea @ [j; w]) in
  let strg' w = str @@ (forall_vars ea @ [j + one; w]) in
  let w = Word.const "w" in
  forall w (strg' w == (ite (w == sk.el j (sc - SI.enc 1)) (sk.el j (sc - SI.enc 2)) (strg w)))

(* effect of instruction on state st after j steps *)
let enc_instruction ea st j is =
  let enc_effect =
    let open Evm_stack in
    match is with
    | PUSH x -> enc_push ea.a st.stack j x
    | POP -> enc_pop st.stack j
    | ADD -> enc_binop st.stack j Word.enc_add
    | SUB -> enc_binop st.stack j Word.enc_sub
    | MUL -> enc_binop st.stack j Word.enc_mul
    | DIV -> enc_binop st.stack j Word.enc_div
    | SDIV -> enc_binop st.stack j Word.enc_sdiv
    | MOD -> enc_binop st.stack j Word.enc_mod
    | SMOD -> enc_binop st.stack j Word.enc_smod
    | ADDMOD -> enc_ternaryop st.stack j Word.enc_addmod
    | MULMOD -> enc_ternaryop st.stack j Word.enc_mulmod
    | LT -> enc_binop st.stack j Word.enc_lt
    | GT -> enc_binop st.stack  j Word.enc_gt
    | SLT -> enc_binop st.stack j Word.enc_slt
    | SGT -> enc_binop st.stack j Word.enc_sgt
    | EQ -> enc_binop st.stack j Word.enc_eq
    | ISZERO -> enc_unaryop st.stack j Word.enc_iszero
    | AND -> enc_binop st.stack j Word.enc_and
    | OR -> enc_binop st.stack j Word.enc_or
    | XOR -> enc_binop st.stack j Word.enc_xor
    | NOT -> enc_unaryop st.stack j Word.enc_not
    | SWAP idx -> enc_swap st.stack j (idx_to_enum idx)
    | DUP idx -> enc_dup st.stack j (idx_to_enum idx)
    | SLOAD -> enc_sload ea st j
    | SSTORE -> enc_sstore ea st.stack st.storage j
    | _ when List.mem uninterpreted is ~equal:Instruction.equal ->
      if is_const is then enc_const_uninterpreted ea st.stack j is
      else enc_nonconst_uninterpreted ea st.stack j is
    | i -> failwith ("Encoding for " ^ [%show: Instruction.t] i ^ " not implemented.")
  in
  let (d, a) = delta_alpha is in let diff = (a - d) in
  let open Z3Ops in
  let sc = st.stack.ctr @@ [j] in
  let sk n = st.stack.el j n
  and sk' n = st.stack.el (j + one) n in
  let strg w = st.storage @@ (forall_vars ea @ [j; w])
  and strg' w = st.storage @@ (forall_vars ea @ [j + one; w]) in
  let ug = st.used_gas @@ (forall_vars ea @ [j])
  and ug' = st.used_gas @@ (forall_vars ea @ [j + one]) in
  let enc_used_gas =
    let cost =
      let k = sk (sc - SI.enc 1) in
      let v' = sk (sc - SI.enc 2) in
      let refund = GC.enc (GC.of_int 15000)
      and set = GC.enc (GC.of_int 20000)
      and reset = GC.enc (GC.of_int 5000) in
      match is with
      | SSTORE ->
        ite (strg k == Word.enc_int 0)
          (ite (v' == Word.enc_int 0) reset set)
          (ite (v' == Word.enc_int 0) (reset - refund) reset)
      | _ -> GC.enc (gas_cost is)
    in
    ug' == (ug + cost)
  in
  let enc_stack_ctr =
    st.stack.ctr @@ [j + one] == (sc + SI.enc diff)
  in
  let enc_exc_halt =
    let underflow = if Int.is_positive d then (sc - (SI.enc d)) < (SI.enc 0) else btm in
    let overflow =
      if Int.is_positive diff then
        match Z3.Sort.get_sort_kind !SI.sort with
        | BV_SORT -> ~! (nuw sc (SI.enc diff) `Add)
        | INT_SORT -> (sc + (SI.enc diff)) > (SI.enc 1024)
        | _ -> btm
      else btm
    in
    st.exc_halt @@ [j + one] == (st.exc_halt @@ [j] || underflow || overflow)
  in
  let enc_pres =
    let pres_storage = match is with
      | SSTORE -> top
      | _ ->
        let w = Word.const "w" in
        forall w (strg' w == strg w)
    in
    let n = SI.const "n" in
    (* all words below d stay the same *)
    (forall n ((n < sc - SI.enc d) ==> (sk' n == sk n))) && pres_storage
  in
  enc_effect && enc_used_gas && enc_stack_ctr && enc_pres && enc_exc_halt

let enc_search_space ea st =
  let open Z3Ops in
  let j = PC.const "j" in
  let enc_cis =
    List.map ea.cis ~f:(fun is ->
        (ea.fis @@ [j] == Opcode.enc (Opcode.from_instr ea.opcodes is)) ==> (enc_instruction ea st j is))
  in
  (* optimization potential:
     choose opcodes = 1 .. |cis| and demand fis (j) < |cis| *)
  let in_cis =
    List.map ea.cis ~f:(fun is -> ea.fis @@ [j] == Opcode.enc (Opcode.from_instr ea.opcodes is))
  in
  forall j (((j < ea.kt) && (j >= PC.init)) ==> conj enc_cis && disj in_cis) &&
  ea.kt >= PC.init

let enc_equivalence_at ea sts stt js jt =
  let open Z3Ops in
  let w = Word.const "w" in
  Evm_stack.enc_equiv_at sts.stack stt.stack js jt &&
  (* source and target exceptional halting are equal *)
  sts.exc_halt @@ [js] == stt.exc_halt @@ [jt] &&
  (* source and target storage are equal *)
  (forall w ((sts.storage @@ (forall_vars ea @ [js; w]))
              == (stt.storage @@ (forall_vars ea @ [jt; w]))))

(* we only demand equivalence at kt *)
let enc_equivalence ea sts stt =
  let ks = PC.enc (Program.length ea.p) and kt = ea.kt in
  let open Z3Ops in
  (* intially source and target states equal *)
  enc_equivalence_at ea sts stt PC.init PC.init &&
  (* initally source and target gas are equal *)
  sts.used_gas @@ (forall_vars ea @ [PC.init]) ==
  stt.used_gas @@ (forall_vars ea @ [PC.init]) &&
  (* after the programs have run source and target states equal *)
  enc_equivalence_at ea sts stt ks kt

let enc_program ea st =
  List.foldi ~init:(init ea st)
    ~f:(fun j enc oc -> enc <&> enc_instruction ea st (PC.enc (PC.of_int j)) oc) ea.p

let enc_super_opt ea =
  let open Z3Ops in
  let sts = Evm_state.mk ea "_s" in
  let stt = Evm_state.mk ea "_t" in
  let ks = PC.enc (Program.length ea.p) in
  foralls (forall_vars ea)
    (enc_program ea sts &&
     enc_search_space ea stt &&
     enc_equivalence ea sts stt &&
     sts.used_gas @@ (forall_vars ea @ [ks]) >
     stt.used_gas @@ (forall_vars ea @ [ea.kt]) &&
     (* bound the number of instructions in the target; aids solver in showing
        unsat, i.e., that program is optimal *)
     ea.kt <= PC.enc (PC.of_int (GC.to_int (total_gas_cost ea.p))))

let enc_trans_val ea tp =
  let open Z3Ops in
  let sts = Evm_state.mk ea "_s" in
  let stt = Evm_state.mk ea "_t" in
  let kt = PC.enc (Program.length tp) and ks = PC.enc (Program.length ea.p) in
  (* we're asking for inputs that distinguish the programs *)
  existss (ea.xs @ List.concat (Map.data ea.uis))
    (* encode source and target program *)
    ((List.foldi tp ~init:(enc_program ea sts)
        ~f:(fun j enc oc -> enc <&> enc_instruction ea stt (PC.enc (PC.of_int j)) oc)) &&
     (* they start in the same state *)
     (enc_equivalence_at ea sts stt PC.init PC.init) &&
     sts.used_gas @@ (forall_vars ea @ [PC.init]) ==
     stt.used_gas @@ (forall_vars ea @ [PC.init]) &&
     (* but their final state is different *)
     ~! (enc_equivalence_at ea sts stt ks kt))

(* classic superoptimzation: generate & test *)
let enc_classic_so_test ea cp js =
  let open Z3Ops in
  let sts = Evm_state.mk ea "_s" in
  let stc = Evm_state.mk ea "_c" in
  let kt = PC.enc (Program.length cp) and ks = PC.enc (Program.length ea.p) in
  foralls (forall_vars ea)
    (* encode source program*)
    ((enc_program ea sts) &&
     (* all instructions from candidate program are used in some order *)
     distinct js &&
     (conj (List.map js ~f:(fun j -> (j < kt) && (j >= PC.init)))) &&
     (* encode instructions from candidate program *)
     conj (List.map2_exn cp js ~f:(fun i j -> enc_instruction ea stc j i)) &&
     (* they start in the same state *)
     (enc_equivalence_at ea sts stc PC.init PC.init) &&
     sts.used_gas @@ (forall_vars ea @ [PC.init]) ==
     stc.used_gas @@ (forall_vars ea @ [PC.init]) &&
     (* and their final state is the same *)
     (enc_equivalence_at ea sts stc ks kt))


let eval_fis ea m j = eval_state_func_decl m j ea.fis |> Opcode.dec

let eval_a ea m j = eval_state_func_decl m j ea.a |> Z3.Arithmetic.Integer.numeral_to_string

let dec_push ea m j = function
  | PUSH Tmpl -> PUSH (Word (Word.from_string (eval_a ea m j)))
  | i -> i

let dec_instr ea m j =
  eval_fis ea m j |> Opcode.to_instr ea.opcodes |> dec_push ea m j

let dec_super_opt ea m =
  let k = PC.dec @@ eval_const m ea.kt in
  Program.init k ~f:(dec_instr ea m)

let dec_classic_super_opt ea m cp js =
  let js = List.map js ~f:(fun j -> eval_const m j |> PC.dec) in
  List.sort ~compare:(fun (_, j1) (_, j2) -> PC.compare j1 j2) (List.zip_exn cp js)
  |> List.mapi ~f:(fun j (i, _) -> dec_push ea m (PC.of_int j) i)
