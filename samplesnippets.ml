open Core
open Instruction

module Snippet_mod = struct
  module T = struct
    type t = string [@@deriving sexp]
    let wsz = ref 0

    let set_wsz s = wsz := s

    let abstract_pusharg sp =
      Sedlexing.Latin1.from_string sp |> Parser.parse
      |> Program.val_to_const !wsz
      |> List.mapi ~f:(fun j i ->
          match i with PUSH (Const _) -> PUSH (Const (Int.to_string j)) | _ -> i)

    let equal sp1 sp2 =
      let p1 = abstract_pusharg sp1
      and p2 = abstract_pusharg sp2 in
      Program.equal p1 p2

    let compare sp1 sp2 =
      if equal sp1 sp2 then 0
      else
        let lc = Int.compare (String.length sp1) (String.length sp2) in
        if lc <> 0 then lc else String.compare sp1 sp2
  end

  include T
  include Comparable.Make(T)
end

let () =
  let open Command.Let_syntax in
  Command.basic ~summary:"sample snippets from csv"
    [%map_open
      let f = anon ("CSVFILE" %: string)
      and wordsize = flag "word-size" (required int)
          ~doc:"wsz word size, i.e., number of bits used for stack elements"
      and outfile = flag "outfile" (optional_with_default "sorted.csv" string)
          ~doc:"f.csv save result to f.csv"
      in
      fun () ->
        Snippet_mod.set_wsz wordsize;
        let m = Map.empty (module Snippet_mod) in
        let c = Csv.Rows.load ~has_header:true f |> List.map ~f:Csv.Row.to_list in
        let ps = List.map c ~f:List.hd_exn in
        let m =
          List.fold_left ps ~init:m
            ~f:(Map.update ~f:(function | None -> Z.one | Some n -> Z.succ n))
        in
        let outcsv =
          List.map (Map.to_alist ~key_order:`Increasing m)
            ~f:(fun (k, d) -> [k; Z.to_string d])
        in
        Csv.save outfile (["byte code"; "count"] :: outcsv)
    ]
  |> Command.run
