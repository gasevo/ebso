open Core
open Z3util
open Instruction
open Program

(* stack address size; design decision/quick fix: the slot 2^sas - 1 is reserved
   for exception handling, otherwise the stack counter wraps around
   --> max stack size 2^sas - 1 *)
let sas = ref 6
(* word size *)
let wsz = ref 3
let sasort = ref (bv_sort !sas)
let wsort = ref (bv_sort !wsz)

let set_wsz n = wsz := n; wsort := bv_sort !wsz
let set_sas s = sas := s; sasort := bv_sort !sas

let senum n = Z3.Expr.mk_numeral_int !ctxt n !wsort
let sanum n = Z3.Expr.mk_numeral_int !ctxt n !sasort
let seconst s = Z3.Expr.mk_const_s !ctxt s !wsort
let saconst s = Z3.Expr.mk_const_s !ctxt s !sasort

type enc_consts = {
  p : Program.t;
  sis : Instruction.t list;
  kt : Z3.Expr.expr;
  fis : Z3.FuncDecl.func_decl;
  a : Z3.FuncDecl.func_decl;
  cs : Z3.Expr.expr list;
  uis : Z3.Expr.expr list;
  opcodes : (Instruction.t * int) list;
  xs : Z3.Expr.expr list;
}

let mk_enc_consts p sis =
  let const_pushs = List.map (Program.consts p) ~f:(fun c -> PUSH (Const c)) in
  let (unints, unint_names) = List.unzip (Program.unints p) in
  let sis = match sis with
    | `All -> Instruction.encodable @ const_pushs @ unints
    | `Progr -> sis_of_progr p
    | `User sis -> List.stable_dedup sis
  in
{ (* source program *)
  p = p;
  (* set of potential instructions to choose from in target program *)
  sis = sis;
  (* number of instructions in target program *)
  kt = intconst "k";
  (* target program *)
  fis = func_decl "instr" [int_sort] int_sort;
  (* arguments for PUSH instrucions in target program *)
  a = func_decl "a" [int_sort] !wsort;
  (* arguments of PUSH which are too large to fit in word size *)
  cs = List.map (Program.consts p) ~f:(seconst);
  (* variables for uninterpreted instructions *)
  uis = List.map unint_names ~f:(seconst);
  (* integer encoding of opcodes *)
  opcodes = List.mapi sis ~f:(fun i oc -> (oc, i));
  (* list of free variables x_0 .. x_(stack_depth -1) for words already on stack *)
  (* careful: no check that this does not generate more than max stacksize variables *)
  xs = List.init (stack_depth p) ~f:(fun i -> seconst ("x_" ^ Int.to_string i));
}

type state = {
  stack : Z3.FuncDecl.func_decl;
  stack_ctr : Z3.FuncDecl.func_decl;
  exc_halt : Z3.FuncDecl.func_decl;
  used_gas : Z3.FuncDecl.func_decl;
}

let mk_state ea idx =
  let xs_sorts = List.map ea.xs ~f:(fun _ -> !wsort) in
  let cs_sorts = List.map ea.cs ~f:(fun _ -> !wsort) in
  let uis_sorts = List.map ea.uis ~f:(fun _ -> !wsort) in
  { (* stack(x0 ... x(sd-1), j, n) = nth word on stack after j instructions
       starting from a stack that contained words x0 ... x(sd-1) *)
    stack = func_decl ("stack" ^ idx)
        (xs_sorts @ cs_sorts @ uis_sorts @ [int_sort; !sasort]) !wsort;
    (* sc(j) = index of the next free slot on the stack after j instructions *)
    stack_ctr = func_decl ("sc" ^ idx) [int_sort] !sasort;
    (* exc_halt(j) is true if exceptional halting occurs after j instructions *)
    exc_halt = func_decl ("exc_halt" ^ idx) [int_sort] bool_sort;
    (* gas(j) = amount of gas used to execute the first j instructions *)
    used_gas = func_decl ("used_gas" ^ idx) [int_sort] int_sort;
  }

let enc_opcode ea i = List.Assoc.find_exn ea.opcodes ~equal:[%eq: Instruction.t] i

let dec_opcode ea i =
  List.Assoc.find_exn (List.Assoc.inverse ea.opcodes) ~equal:[%eq: int] i

let init ea st =
  let open Z3Ops in
  (* careful: if stack_depth is larger than 2^sas, no checks *)
  let skd = stack_depth (ea.p) in
  (* set stack counter to skd *)
  (st.stack_ctr @@ [num 0] == sanum skd)
  (* set inital words on stack *)
  && conj (List.mapi ea.xs ~f:(fun i x ->
      st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [num 0; sanum i]) == x))
  && (st.exc_halt @@ [num 0] == btm)
  && (st.used_gas @@ [num 0] == num 0)

(* TODO: check data layout on stack *)
let enc_stackarg ea j = function
  (* careful: if x is to large for wsort leftmost bits are truncated *)
  | Stackarg.Val x -> Z3.Expr.mk_numeral_string !ctxt (Stackarg.valarg_to_dec x) !wsort
  | Tmpl -> ea.a <@@> [j]
  | Const c -> seconst c

let enc_push ea st j x =
  let open Z3Ops in
  (* the stack after the PUSH *)
  let sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  (* the stack counter before the PUSH *)
  let sc = st.stack_ctr @@ [j] in
  (* the new top word will be x *)
  sk' sc == enc_stackarg ea j x

(* the only effect of POP is to change the stack counter *)
let enc_pop _ _ _ = top

let enc_binop ea st j op =
  let open Z3Ops in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let sc = st.stack_ctr @@ [j] in
  (* the new top word is the result of applying op to the previous two *)
  (sk' (sc - sanum 2) == op (sk (sc - sanum 1)) (sk (sc - sanum 2)))

let enc_add ea st j = enc_binop ea st j (<+>)
let enc_sub ea st j = enc_binop ea st j (<->)
let enc_mul ea st j = enc_binop ea st j (<*>)
let enc_div ea st j =
  (* EVM defines x / 0 = 0, Z3 says it's undefined *)
  let div num denom = ite (denom <==> senum 0) (senum 0) (udiv num denom) in
  enc_binop ea st j div
let enc_sdiv ea st j =
  (* EVM defines x / 0 = 0, Z3 says it's undefined *)
  let sdiv num denom = ite (denom <==> senum 0) (senum 0) (sdiv num denom) in
  enc_binop ea st j sdiv
let enc_mod ea st j =
  (* EVM defines x mod 0 = 0, Z3 says it's undefined *)
  let evmmod num denom = ite (denom <==> senum 0) (senum 0) (urem num denom) in
  enc_binop ea st j evmmod
let enc_smod ea st j =
  (* Z3 has srem and smod; srem takes sign from dividend (= num),
     smod from divisor (= denom); EVM takes the latter *)
  (* EVM defines x smod 0 = 0, Z3 says it's undefined *)
  let evmsmod num denom = ite (denom <==> senum 0) (senum 0) (srem num denom) in
  enc_binop ea st j evmsmod

let enc_lt ea st j =
  let bvlt x y = ite (Z3.BitVector.mk_ult !ctxt x y) (senum 1) (senum 0) in
  enc_binop ea st j bvlt
let enc_gt ea st j =
  let bvgt x y = ite (Z3.BitVector.mk_ugt !ctxt x y) (senum 1) (senum 0) in
  enc_binop ea st j bvgt
let enc_slt ea st j =
  let bvslt x y = ite (x <<> y) (senum 1) (senum 0) in
  enc_binop ea st j bvslt
let enc_sgt ea st j =
  let bvsgt x y = ite (x <>> y) (senum 1) (senum 0) in
  enc_binop ea st j bvsgt
let enc_eq ea st j =
  let bveq x y = ite (x <==> y) (senum 1) (senum 0) in
  enc_binop ea st j bveq

let enc_and ea st j = enc_binop ea st j (Z3.BitVector.mk_and !ctxt)
let enc_or ea st j = enc_binop ea st j (Z3.BitVector.mk_or !ctxt)
let enc_xor ea st j = enc_binop ea st j (Z3.BitVector.mk_xor !ctxt)

let enc_addmod ea st j =
  let open Z3Ops in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let sc = st.stack_ctr @@ [j] and sc'= st.stack_ctr @@ [j + one] in
  let denom = sk (sc - sanum 3) and x =  sk (sc - sanum 2) and y =  sk (sc - sanum 1) in
  sk' (sc' - sanum 1) ==
  (* EVM defines (x + y) mod 0 = 0 as 0, Z3 says it's undefined *)
  ite (denom == senum 0) (senum 0) (
    (* truncate back to word size, safe because mod denom brings us back to range *)
    extract (Int.pred !wsz) 0
      (* requires non overflowing add, pad with 0s to avoid overflow *)
      (urem ((zeroext 1 y) + (zeroext 1 x)) (zeroext 1 denom)))

let enc_mulmod ea st j =
  let open Z3Ops in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let sc = st.stack_ctr @@ [j] and sc'= st.stack_ctr @@ [j + one] in
  let denom = sk (sc - sanum 3) and x =  sk (sc - sanum 2) and y =  sk (sc - sanum 1) in
  sk' (sc' - sanum 1) ==
  (* EVM defines (x + y) mod 0 = 0 as 0, Z3 says it's undefined *)
  ite (denom == senum 0) (senum 0) (
    (* truncate back to word size, safe because mod denom brings us back to range *)
    extract (Int.pred !wsz) 0
      (* requires non overflowing mul, pad with 0s to avoid overflow *)
      (urem ((zeroext !wsz y) * (zeroext !wsz x)) (zeroext !wsz denom)))

let enc_not ea st j =
  let open Z3Ops in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let sc = st.stack_ctr @@ [j] and sc'= st.stack_ctr @@ [j + one] in
  (* the new top word is the bitwise negation of the old top word *)
  (sk' (sc' - sanum 1) == Z3.BitVector.mk_not !ctxt (sk (sc - sanum 1)))

let enc_iszero ea st j =
  let open Z3Ops in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let sc = st.stack_ctr @@ [j] and sc'= st.stack_ctr @@ [j + one] in
  (* if the old top word is 0 then the new top word is 1 and 0 otherwise *)
  (sk' (sc' - sanum 1) == ite (sk (sc - sanum 1) == (senum 0)) (senum 1) (senum 0))

let enc_swap ea st j idx =
  let sc_idx = sanum (idx + 1) in
  let open Z3Ops in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let sc = st.stack_ctr @@ [j] and sc'= st.stack_ctr @@ [j + one] in
  (* the new top word is the 1+idx'th from the old stack *)
  (sk' (sc' - sanum 1) == sk (sc - sc_idx)) &&
  (* the new 1+idx'th word is the top from the old stack*)
  (sk' (sc' - sc_idx) == sk (sc - sanum 1)) &&
  (* the words between top and idx+1 are not touched *)
  conj (List.init (Int.pred idx) ~f:(fun i ->
      let sc_iidx = sanum (Int.(-) idx i) in
      (sk' (sc' - sc_iidx) == sk (sc - sc_iidx))))

let enc_dup ea st j idx =
  let sc_idx = sanum idx in
  let open Z3Ops in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let sc = st.stack_ctr @@ [j] and sc'= st.stack_ctr @@ [j + one] in
  (* the new top word is the idx'th from the old stack *)
  (sk' (sc' - sanum 1) == sk (sc - sc_idx)) &&
  (* all words down to idx are not touched *)
  conj (List.init idx ~f:(fun i ->
      let sc_iidx = sanum (Int.(-) idx i) in
      (sk' (sc - sc_iidx) == sk (sc - sc_iidx))))

let enc_number ea st j = enc_push ea st j (Const "NUMBER")

(* effect of instruction on state st after j steps *)
let enc_instruction ea st j is =
  let enc_effect =
    match is with
    | PUSH x -> enc_push ea st j x
    | POP -> enc_pop ea st j
    | ADD -> enc_add ea st j
    | SUB -> enc_sub ea st j
    | MUL -> enc_mul ea st j
    | DIV -> enc_div ea st j
    | SDIV -> enc_sdiv ea st j
    | MOD -> enc_mod ea st j
    | SMOD -> enc_smod ea st j
    | ADDMOD -> enc_addmod ea st j
    | MULMOD -> enc_mulmod ea st j
    | LT -> enc_lt ea st j
    | GT -> enc_gt ea st j
    | SLT -> enc_slt ea st j
    | SGT -> enc_sgt ea st j
    | EQ -> enc_eq ea st j
    | ISZERO -> enc_iszero ea st j
    | AND -> enc_and ea st j
    | OR -> enc_or ea st j
    | XOR -> enc_xor ea st j
    | NOT -> enc_not ea st j
    | SWAP idx -> enc_swap ea st j (idx_to_enum idx)
    | DUP idx -> enc_dup ea st j (idx_to_enum idx)
    | NUMBER -> enc_number ea st j
    | _ -> failwith "not implemented"
  in
  let (d, a) = delta_alpha is in let diff = (a - d) in
  let open Z3Ops in
  let sc = st.stack_ctr @@ [j] in
  let sk n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j; n])
  and sk' n = st.stack @@ (ea.xs @ ea.cs @ ea.uis @ [j + one; n]) in
  let enc_used_gas =
    st.used_gas @@ [j + one] == ((st.used_gas @@ [j]) + (num (gas_cost is)))
  in
  let enc_stack_ctr =
    st.stack_ctr @@ [j + one] == (sc + sanum diff)
  in
  let enc_exc_halt =
    let underflow = if Int.is_positive d then (sc - (sanum d)) < (sanum 0) else btm in
    let overflow =
      if Int.is_positive diff then
        match Z3.Sort.get_sort_kind !sasort with
        | BV_SORT -> ~! (nuw sc (sanum diff) `Add)
        | INT_SORT -> (sc + (sanum diff)) > (sanum 1024)
        | _ -> btm
      else btm
    in
    st.exc_halt @@ [j + one] == (st.exc_halt @@ [j] || underflow || overflow)
  in
  let enc_pres =
    let n = saconst "n" in
    (* all words below d stay the same *)
    forall n ((n < sc - sanum d) ==> (sk' n == sk n))
  in
  enc_effect && enc_used_gas && enc_stack_ctr && enc_pres && enc_exc_halt

let enc_search_space ea st =
  let open Z3Ops in
  let j = intconst "j" in
  let enc_sis =
    List.map ea.sis ~f:(fun is ->
        (ea.fis @@ [j] == num (enc_opcode ea is)) ==> (enc_instruction ea st j is))
  in
  (* optimization potential:
     choose opcodes = 1 .. |sis| and demand fis (j) < |sis| *)
  let in_sis =
    List.map ea.sis ~f:(fun is -> ea.fis @@ [j] == num (enc_opcode ea is))
  in
  forall j (((j < ea.kt) && (j >= (num 0))) ==> conj enc_sis && disj in_sis) &&
  ea.kt >= (num 0)

let enc_equivalence_at ea sts stt js jt =
  let open Z3Ops in
  let n = saconst "n" in
  (* source and target stack counter are equal *)
  sts.stack_ctr @@ [js] == stt.stack_ctr @@ [jt] &&
  (* source and target exceptional halting are equal *)
  sts.exc_halt @@ [js] == stt.exc_halt @@ [jt] &&
  (* source and target stack are equal below the stack counter;
     note that it doesn't matter which stack counter is used, they are equal *)
  (forall n ((n < stt.stack_ctr @@ [jt]) ==>
             ((sts.stack @@ (ea.xs @ ea.cs @ ea.uis @ [js; n]))
              == (stt.stack @@ (ea.xs @ ea.cs @ ea.uis @ [jt; n])))))

(* we only demand equivalence at kt *)
let enc_equivalence ea sts stt =
  let ks = num (List.length ea.p) and kt = ea.kt in
  let open Z3Ops in
  (* intially source and target states equal *)
  enc_equivalence_at ea sts stt (num 0) (num 0) &&
  (* initally source and target gas are equal *)
  sts.used_gas @@ [num 0] == stt.used_gas @@ [num 0] &&
  (* after the programs have run source and target states equal *)
  enc_equivalence_at ea sts stt ks kt

let enc_program ea st =
  List.foldi ~init:(init ea st)
    ~f:(fun j enc oc -> enc <&> enc_instruction ea st (num j) oc) ea.p

let enc_super_opt ea =
  let open Z3Ops in
  let sts = mk_state ea "_s" in
  let stt = mk_state ea "_t" in
  let ks = List.length ea.p in
  foralls (ea.xs @ ea.cs @ ea.uis)
  (enc_program ea sts &&
   enc_search_space ea stt &&
   enc_equivalence ea sts stt &&
   sts.used_gas @@ [num ks] > stt.used_gas @@ [ea.kt] &&
   (* bound the number of instructions in the target; aids solver in showing
      unsat, i.e., that program is optimal *)
   ea.kt <= sts.used_gas @@ [num ks])

let enc_trans_val ea tp =
  let open Z3Ops in
  let sts = mk_state ea "_s" in
  let stt = mk_state ea "_t" in
  let kt = num (List.length tp) and ks = num (List.length ea.p) in
  (* we're asking for inputs that distinguish the programs *)
  existss ea.xs
    (* encode source and target program *)
    ((List.foldi tp ~init:(enc_program ea sts)
        ~f:(fun j enc oc -> enc <&> enc_instruction ea stt (num j) oc)) &&
     (* they start in the same state *)
     (enc_equivalence_at ea sts stt (num 0) (num 0)) &&
     sts.used_gas @@ [num 0] == stt.used_gas @@ [num 0] &&
     (* but their final state is different *)
     ~! (enc_equivalence_at ea sts stt ks kt))

(* classic superoptimzation: generate & test *)

let enc_classic_so_test _ _ = failwith "step1 not implemented"

let eval_stack ?(xs = []) st m i n =
  eval_func_decl m i ~n:[sanum n] ~xs:xs st.stack

let eval_stack_ctr st m i = eval_func_decl m i st.stack_ctr

let eval_exc_halt st m i = eval_func_decl m i st.exc_halt

let eval_gas st m i = eval_func_decl m i st.used_gas |> Z3.Arithmetic.Integer.get_int

let eval_fis ea m j = eval_func_decl m j ea.fis |> Z3.Arithmetic.Integer.get_int

let eval_a ea m j = eval_func_decl m j ea.a |> Z3.Arithmetic.Integer.numeral_to_string

let dec_push ea m j = function
  | PUSH Tmpl -> PUSH (Val (eval_a ea m j))
  | i -> i

let dec_instr ea m j =
  eval_fis ea m j |> dec_opcode ea |> dec_push ea m j

let dec_super_opt ea m =
  let k = Z3.Arithmetic.Integer.get_int @@ eval_const m ea.kt in
  List.init k ~f:(dec_instr ea m)

let dec_classic_super_opt ea m pc = List.mapi pc ~f:(dec_push ea m)
