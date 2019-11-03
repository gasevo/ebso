(*   Copyright 2019 Julian Nagele and Maria A Schett

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

(* a value argument can be either decimal, e.g., "1", hex, e.g., "0x1"
   or binary, e.g. "0b1" *)
type t = Val of string [@printer fun fmt x -> fprintf fmt "%s" x]
       | Const of string [@printer fun fmt x -> fprintf fmt "c%s" x]
[@@deriving show { with_path = false }, sexp, compare]

let size = ref 3

let sort = ref (bv_sort !size)

let to_val w = match w with
  | Const c -> Val c
  | w -> w

let set_wsz n = size := n; sort := bv_sort !size

let rec to_hex = function
  | Val x ->  Z.of_string x |> Z.format "x"
  | Const c -> to_hex (to_val (Const c))

let rec to_dec = function
  | Val x -> Z.of_string x |> Z.to_string
  | Const c -> to_dec (to_val (Const c)) (* convention is that constarg is in dec *)

let enc_int n = Z3.Expr.mk_numeral_int !ctxt n !sort

let const s = Z3.Expr.mk_const_s !ctxt s !sort

let enc = function
  | Const c -> const c
  (* careful: if x is to large for Word.sort leftmost bits are truncated *)
  | Val x ->
    let enc_string n = Z3.Expr.mk_numeral_string !ctxt n !sort in
    enc_string (to_dec (Val x))

let equal w1 w2 = match w1, w2 with
  | Val x, Val y -> Z.equal (Z.of_string x) (Z.of_string y)
  | Const c, Const d -> String.equal c d
  | _ -> false

let show_hex x =
    let hx = to_hex x in
    if Int.rem (String.length hx) 2 = 1 then "0" ^ hx else hx

let to_const w = match w with
  | Val x -> Const (to_dec (Val x))
  | _ -> w

let from_string x = Val x

let numbits x = Z.numbits (Z.of_string (to_dec x))

let fits_wsz wsz = function
  | Const _ -> true
  | w ->
    let max_repr = Z.pow (Z.of_int 2) wsz in
    Z.of_string (to_dec w) < max_repr