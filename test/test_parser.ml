open Core
open OUnit2
open Instruction
open Sedlexing
open Parser

let suite =
  "suite" >:::
  [
    "parse_idx 10" >:: (fun _ ->
        assert_equal ~cmp:[%eq: idx] ~printer:[%show: idx]
          X (parse_idx "SWAP" "SWAP10")
      );

    "parse_idx 1" >:: (fun _ ->
        assert_equal ~cmp:[%eq: idx] ~printer:[%show: idx]
          I (parse_idx "SWAP" "SWAP1")
      );

    "parse_idx fail 17" >:: (fun _ ->
        assert_raises (Info.to_exn @@ Info.of_string @@ "parse SWAP index failed")
          (fun () -> parse_idx "SWAP" "SWAP17")
      );

    "parse_idx fail -1" >:: (fun _ ->
        assert_raises (Info.to_exn @@ Info.of_string @@ "parse SWAP index failed")
          (fun () -> parse_idx "SWAP" "SWAP-1")
      );

    "parse_idx fail a" >:: (fun _ ->
        assert_raises (Failure "Int.of_string: \"a\"")
          (fun () -> parse_idx "SWAP" "SWAPa")
      );

    "parse instruction list" >:: (fun _ ->
        let s = List.to_string ~f:Instruction.show Instruction.encodable in
        let buf = Latin1.from_string s in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          Instruction.encodable
          (parse buf)
      );

    "parse instruction list fail B" >:: (fun _ ->
        let buf = Latin1.from_string "ADD B SWAP1" in
        assert_raises (SyntaxError 4)
          (fun () -> parse buf)
      );

    (* hex parsing *)

    "parse_hex_idx DUP1" >:: (fun _ ->
        assert_equal ~cmp:[%eq: idx] ~printer:[%show: idx]
          I (parse_hex_idx "80" 127)
      );
    "parse_hex_idx DUP16" >:: (fun _ ->
        assert_equal ~cmp:[%eq: idx] ~printer:[%show: idx]
          XVI (parse_hex_idx "8f" 127)
      );
    "parse_hex_idx SWAP1" >:: (fun _ ->
        assert_equal ~cmp:[%eq: idx] ~printer:[%show: idx]
          I (parse_hex_idx "90" 143)
      );
    "parse_hex_idx SWAP16" >:: (fun _ ->
        assert_equal ~cmp:[%eq: idx] ~printer:[%show: idx]
          XVI (parse_hex_idx "9f" 143)
      );

    "parse stack argument hex" >:: (fun _ ->
        let buf = Latin1.from_string "aa0066ee" in
        assert_equal ~cmp:[%eq: int] ~printer:[%show: int]
          2852153070 (parse_hex_bytes 4 buf)
      );

    "parse PUSH1 from bytexode" >:: (fun _ ->
        let buf = Latin1.from_string "6080" in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          [PUSH (Val 128)] (parse_hex buf)
      );

    "parse PUSH32 from bytexode" >:: (fun _ ->
        let s = "7f0000000000000000000000000000000000000000000000000000000000000010" in
        let buf = Latin1.from_string s in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          [PUSH (Val 16)] (parse_hex buf)
      );

    "parse DUP1 from bytexode" >:: (fun _ ->
        let s = "80" in
        let buf = Latin1.from_string s in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          [DUP I] (parse_hex buf)
      );

    "parse DUP16 from bytexode" >:: (fun _ ->
        let s = "8f" in
        let buf = Latin1.from_string s in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          [DUP XVI] (parse_hex buf)
      );

    "parse SWAP1 from bytexode" >:: (fun _ ->
        let s = "90" in
        let buf = Latin1.from_string s in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          [SWAP I] (parse_hex buf)
      );

    "parse SWAP16 from bytexode" >:: (fun _ ->
        let s = "9f" in
        let buf = Latin1.from_string s in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          [SWAP XVI] (parse_hex buf)
      );

    "parse contract from bytecode" >:: (fun _ ->
        let s =
          "608060405234801561001057600080fd5b5060a68061001f6000396000f300608060\
           405260043610603e5763ffffffff6000350416633120d43481146043575b600080fd\
           5b348015604e57600080fd5b50605b60ff600435166071565b6040805160ff909216\
           8252519081900360200190f35b600003602a01905600"
        in
        let buf = Latin1.from_string s in
        assert_equal ~cmp:[%eq: Instruction.t list] ~printer:[%show: Instruction.t list]
          [PUSH (Val 128); PUSH (Val 64); MSTORE; CALLVALUE; DUP I; ISZERO;
           PUSH (Val 16); JUMPI; PUSH (Val 0); DUP I; REVERT; JUMPDEST; POP;
           PUSH (Val 166); DUP I; PUSH (Val 31); PUSH (Val 0); CODECOPY;
           PUSH (Val 0); RETURN; STOP; PUSH (Val 128); PUSH (Val 64); MSTORE;
           PUSH (Val 4); CALLDATASIZE; LT; PUSH (Val 62); JUMPI;
           PUSH (Val 4294967295); PUSH (Val 0); CALLDATALOAD; DIV; AND;
           PUSH (Val 824235060); DUP II; EQ; PUSH (Val 67); JUMPI; JUMPDEST;
           PUSH (Val 0); DUP I; REVERT; JUMPDEST; CALLVALUE; DUP I; ISZERO;
           PUSH (Val 78); JUMPI; PUSH (Val 0); DUP I; REVERT; JUMPDEST; POP;
           PUSH (Val 91); PUSH (Val 255); PUSH (Val 4); CALLDATALOAD; AND;
           PUSH (Val 113); JUMP; JUMPDEST; PUSH (Val 64); DUP I; MLOAD;
           PUSH (Val 255); SWAP I; SWAP III; AND; DUP III; MSTORE; MLOAD; SWAP I;
           DUP II; SWAP I; SUB; PUSH (Val 32); ADD; SWAP I; RETURN; JUMPDEST;
           PUSH (Val 0); SUB; PUSH (Val 42); ADD; SWAP I; JUMP; STOP]
          (parse_hex buf)
      );
  ]

let () =
  run_test_tt_main suite
