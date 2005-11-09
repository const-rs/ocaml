(***********************************************************************)
(*                                                                     *)
(*                           Objective Caml                            *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id$ *)

(* Translation from typed abstract syntax to lambda terms,
   for the core language *)

open Misc
open Asttypes
open Primitive
open Path
open Types
open Typedtree
open Typeopt
open Lambda

type error =
    Illegal_letrec_pat
  | Illegal_letrec_expr
  | Free_super_var
  | Unsupported_type_constructor

exception Error of Location.t * error

(* Forward declaration -- to be filled in by Translmod.transl_module *)
let transl_module =
  ref((fun cc rootpath modl -> assert false) :
      module_coercion -> Path.t option -> module_expr -> lambda)

let transl_object =
  ref (fun id s cl -> assert false :
       Ident.t -> string list -> class_expr -> lambda)

(* Translation of primitives *)

let comparisons_table = create_hashtable 11 [
  "%equal",
      (Pccall{prim_name = "caml_equal"; prim_arity = 2; prim_alloc = true;
              prim_native_name = ""; prim_native_float = false},
       Pintcomp Ceq,
       Pfloatcomp Ceq,
       Pccall{prim_name = "caml_string_equal"; prim_arity = 2;
              prim_alloc = false;
              prim_native_name = ""; prim_native_float = false},
       Pbintcomp(Pnativeint, Ceq),
       Pbintcomp(Pint32, Ceq),
       Pbintcomp(Pint64, Ceq),
       true);
  "%notequal",
      (Pccall{prim_name = "caml_notequal"; prim_arity = 2; prim_alloc = true;
              prim_native_name = ""; prim_native_float = false},
       Pintcomp Cneq,
       Pfloatcomp Cneq,
       Pccall{prim_name = "caml_string_notequal"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pbintcomp(Pnativeint, Cneq),
       Pbintcomp(Pint32, Cneq),
       Pbintcomp(Pint64, Cneq),
       true);
  "%lessthan",
      (Pccall{prim_name = "caml_lessthan"; prim_arity = 2; prim_alloc = true;
              prim_native_name = ""; prim_native_float = false},
       Pintcomp Clt,
       Pfloatcomp Clt,
       Pccall{prim_name = "caml_string_lessthan"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pbintcomp(Pnativeint, Clt),
       Pbintcomp(Pint32, Clt),
       Pbintcomp(Pint64, Clt),
       false);
  "%greaterthan",
      (Pccall{prim_name = "caml_greaterthan"; prim_arity = 2; prim_alloc = true;
              prim_native_name = ""; prim_native_float = false},
       Pintcomp Cgt,
       Pfloatcomp Cgt,
       Pccall{prim_name = "caml_string_greaterthan"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pbintcomp(Pnativeint, Cgt),
       Pbintcomp(Pint32, Cgt),
       Pbintcomp(Pint64, Cgt),
       false);
  "%lessequal",
      (Pccall{prim_name = "caml_lessequal"; prim_arity = 2; prim_alloc = true;
              prim_native_name = ""; prim_native_float = false},
       Pintcomp Cle,
       Pfloatcomp Cle,
       Pccall{prim_name = "caml_string_lessequal"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pbintcomp(Pnativeint, Cle),
       Pbintcomp(Pint32, Cle),
       Pbintcomp(Pint64, Cle),
       false);
  "%greaterequal",
      (Pccall{prim_name = "caml_greaterequal"; prim_arity = 2;
              prim_alloc = true;
              prim_native_name = ""; prim_native_float = false},
       Pintcomp Cge,
       Pfloatcomp Cge,
       Pccall{prim_name = "caml_string_greaterequal"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pbintcomp(Pnativeint, Cge),
       Pbintcomp(Pint32, Cge),
       Pbintcomp(Pint64, Cge),
       false);
  "%compare",
      (Pccall{prim_name = "caml_compare"; prim_arity = 2; prim_alloc = true;
              prim_native_name = ""; prim_native_float = false},
       Pccall{prim_name = "caml_int_compare"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pccall{prim_name = "caml_float_compare"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pccall{prim_name = "caml_string_compare"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pccall{prim_name = "caml_nativeint_compare"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pccall{prim_name = "caml_int32_compare"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       Pccall{prim_name = "caml_int64_compare"; prim_arity = 2;
              prim_alloc = false; prim_native_name = "";
              prim_native_float = false},
       false)
]

let primitives_table = create_hashtable 57 [
  "%identity", Pidentity;
  "%ignore", Pignore;
  "%field0", Pfield 0;
  "%field1", Pfield 1;
  "%setfield0", Psetfield(0, true);
  "%makeblock", Pmakeblock(0, Immutable);
  "%makemutable", Pmakeblock(0, Mutable);
  "%raise", Praise;
  "%sequand", Psequand;
  "%sequor", Psequor;
  "%boolnot", Pnot;
  "%negint", Pnegint;
  "%succint", Poffsetint 1;
  "%predint", Poffsetint(-1);
  "%addint", Paddint;
  "%subint", Psubint;
  "%mulint", Pmulint;
  "%divint", Pdivint;
  "%modint", Pmodint;
  "%andint", Pandint;
  "%orint", Porint;
  "%xorint", Pxorint;
  "%lslint", Plslint;
  "%lsrint", Plsrint;
  "%asrint", Pasrint;
  "%eq", Pintcomp Ceq;
  "%noteq", Pintcomp Cneq;
  "%ltint", Pintcomp Clt;
  "%leint", Pintcomp Cle;
  "%gtint", Pintcomp Cgt;
  "%geint", Pintcomp Cge;
  "%incr", Poffsetref(1);
  "%decr", Poffsetref(-1);
  "%intoffloat", Pintoffloat;
  "%floatofint", Pfloatofint;
  "%negfloat", Pnegfloat;
  "%absfloat", Pabsfloat;
  "%addfloat", Paddfloat;
  "%subfloat", Psubfloat;
  "%mulfloat", Pmulfloat;
  "%divfloat", Pdivfloat;
  "%eqfloat", Pfloatcomp Ceq;
  "%noteqfloat", Pfloatcomp Cneq;
  "%ltfloat", Pfloatcomp Clt;
  "%lefloat", Pfloatcomp Cle;
  "%gtfloat", Pfloatcomp Cgt;
  "%gefloat", Pfloatcomp Cge;
  "%string_length", Pstringlength;
  "%string_safe_get", Pstringrefs;
  "%string_safe_set", Pstringsets;
  "%string_unsafe_get", Pstringrefu;
  "%string_unsafe_set", Pstringsetu;
  "%array_length", Parraylength Pgenarray;
  "%array_safe_get", Parrayrefs Pgenarray;
  "%array_safe_set", Parraysets Pgenarray;
  "%array_unsafe_get", Parrayrefu Pgenarray;
  "%array_unsafe_set", Parraysetu Pgenarray;
  "%obj_size", Parraylength Pgenarray;
  "%obj_field", Parrayrefu Pgenarray;
  "%obj_set_field", Parraysetu Pgenarray;
  "%obj_is_int", Pisint;
  "%nativeint_of_int", Pbintofint Pnativeint;
  "%nativeint_to_int", Pintofbint Pnativeint;
  "%nativeint_neg", Pnegbint Pnativeint;
  "%nativeint_add", Paddbint Pnativeint;
  "%nativeint_sub", Psubbint Pnativeint;
  "%nativeint_mul", Pmulbint Pnativeint;
  "%nativeint_div", Pdivbint Pnativeint;
  "%nativeint_mod", Pmodbint Pnativeint;
  "%nativeint_and", Pandbint Pnativeint;
  "%nativeint_or",  Porbint Pnativeint;
  "%nativeint_xor", Pxorbint Pnativeint;
  "%nativeint_lsl", Plslbint Pnativeint;
  "%nativeint_lsr", Plsrbint Pnativeint;
  "%nativeint_asr", Pasrbint Pnativeint;
  "%int32_of_int", Pbintofint Pint32;
  "%int32_to_int", Pintofbint Pint32;
  "%int32_neg", Pnegbint Pint32;
  "%int32_add", Paddbint Pint32;
  "%int32_sub", Psubbint Pint32;
  "%int32_mul", Pmulbint Pint32;
  "%int32_div", Pdivbint Pint32;
  "%int32_mod", Pmodbint Pint32;
  "%int32_and", Pandbint Pint32;
  "%int32_or",  Porbint Pint32;
  "%int32_xor", Pxorbint Pint32;
  "%int32_lsl", Plslbint Pint32;
  "%int32_lsr", Plsrbint Pint32;
  "%int32_asr", Pasrbint Pint32;
  "%int64_of_int", Pbintofint Pint64;
  "%int64_to_int", Pintofbint Pint64;
  "%int64_neg", Pnegbint Pint64;
  "%int64_add", Paddbint Pint64;
  "%int64_sub", Psubbint Pint64;
  "%int64_mul", Pmulbint Pint64;
  "%int64_div", Pdivbint Pint64;
  "%int64_mod", Pmodbint Pint64;
  "%int64_and", Pandbint Pint64;
  "%int64_or",  Porbint Pint64;
  "%int64_xor", Pxorbint Pint64;
  "%int64_lsl", Plslbint Pint64;
  "%int64_lsr", Plsrbint Pint64;
  "%int64_asr", Pasrbint Pint64;
  "%nativeint_of_int32", Pcvtbint(Pint32, Pnativeint);
  "%nativeint_to_int32", Pcvtbint(Pnativeint, Pint32);
  "%int64_of_int32", Pcvtbint(Pint32, Pint64);
  "%int64_to_int32", Pcvtbint(Pint64, Pint32);
  "%int64_of_nativeint", Pcvtbint(Pnativeint, Pint64);
  "%int64_to_nativeint", Pcvtbint(Pint64, Pnativeint);
  "%bigarray_ref_1", Pbigarrayref(1, Pbigarray_unknown, Pbigarray_c_layout);
  "%bigarray_ref_2", Pbigarrayref(2, Pbigarray_unknown, Pbigarray_c_layout);
  "%bigarray_ref_3", Pbigarrayref(3, Pbigarray_unknown, Pbigarray_c_layout);
  "%bigarray_set_1", Pbigarrayset(1, Pbigarray_unknown, Pbigarray_c_layout);
  "%bigarray_set_2", Pbigarrayset(2, Pbigarray_unknown, Pbigarray_c_layout);
  "%bigarray_set_3", Pbigarrayset(3, Pbigarray_unknown, Pbigarray_c_layout)
]

let prim_makearray =
  { prim_name = "caml_make_vect"; prim_arity = 2; prim_alloc = true;
    prim_native_name = ""; prim_native_float = false }

let prim_obj_dup =
  { prim_name = "caml_obj_dup"; prim_arity = 1; prim_alloc = true;
    prim_native_name = ""; prim_native_float = false }

let transl_prim prim args =
  try
    let (gencomp, intcomp, floatcomp, stringcomp,
         nativeintcomp, int32comp, int64comp,
         simplify_constant_constructor) =
      Hashtbl.find comparisons_table prim.prim_name in
    begin match args with
      [arg1; {exp_desc = Texp_construct({cstr_tag = Cstr_constant _}, _)}]
      when simplify_constant_constructor ->
        intcomp
    | [{exp_desc = Texp_construct({cstr_tag = Cstr_constant _}, _)}; arg2]
      when simplify_constant_constructor ->
        intcomp
    | [arg1; arg2] when has_base_type arg1 Predef.path_int
                     || has_base_type arg1 Predef.path_char ->
        intcomp
    | [arg1; arg2] when has_base_type arg1 Predef.path_float ->
        floatcomp
    | [arg1; arg2] when has_base_type arg1 Predef.path_string ->
        stringcomp
    | [arg1; arg2] when has_base_type arg1 Predef.path_nativeint ->
        nativeintcomp
    | [arg1; arg2] when has_base_type arg1 Predef.path_int32 ->
        int32comp
    | [arg1; arg2] when has_base_type arg1 Predef.path_int64 ->
        int64comp
    | _ ->
        gencomp
    end
  with Not_found ->
  try
    let p = Hashtbl.find primitives_table prim.prim_name in
    (* Try strength reduction based on the type of the argument *)
    begin match (p, args) with
        (Psetfield(n, _), [arg1; arg2]) -> Psetfield(n, maybe_pointer arg2)
      | (Parraylength Pgenarray, [arg])   -> Parraylength(array_kind arg)
      | (Parrayrefu Pgenarray, arg1 :: _) -> Parrayrefu(array_kind arg1)
      | (Parraysetu Pgenarray, arg1 :: _) -> Parraysetu(array_kind arg1)
      | (Parrayrefs Pgenarray, arg1 :: _) -> Parrayrefs(array_kind arg1)
      | (Parraysets Pgenarray, arg1 :: _) -> Parraysets(array_kind arg1)
      | (Pbigarrayref(n, Pbigarray_unknown, _), arg1 :: _) ->
            let (k, l) = bigarray_kind_and_layout arg1 in
            Pbigarrayref(n, k, l)
      | (Pbigarrayset(n, Pbigarray_unknown, _), arg1 :: _) ->
            let (k, l) = bigarray_kind_and_layout arg1 in
            Pbigarrayset(n, k, l)
      | _ -> p
    end
  with Not_found ->
    Pccall prim


(* Eta-expand a primitive without knowing the types of its arguments *)

let transl_primitive p =
  let prim =
    try
      let (gencomp, _, _, _, _, _, _, _) =
        Hashtbl.find comparisons_table p.prim_name in
      gencomp
    with Not_found ->
    try
      Hashtbl.find primitives_table p.prim_name
    with Not_found ->
      Pccall p in
  let rec make_params n =
    if n <= 0 then [] else Ident.create "prim" :: make_params (n-1) in
  let params = make_params p.prim_arity in
  Lfunction(Curried, params, Lprim(prim, List.map (fun id -> Lvar id) params))

(* To check the well-formedness of r.h.s. of "let rec" definitions *)

let check_recursive_lambda idlist lam =
  let rec check_top idlist = function
    | Lvar v -> not (List.mem v idlist)
    | Llet (_, _, _, _) as lam when check_recursive_recordwith idlist lam ->
        true
    | Llet(str, id, arg, body) ->
        check idlist arg && check_top (add_let id arg idlist) body
    | Lletrec(bindings, body) ->
        let idlist' = add_letrec bindings idlist in
        List.for_all (fun (id, arg) -> check idlist' arg) bindings &&
        check_top idlist' body
    | Lsequence (lam1, lam2) -> check idlist lam1 && check_top idlist lam2
    | Levent (lam, _) -> check_top idlist lam
    | lam -> check idlist lam

  and check idlist = function
    | Lvar _ -> true
    | Lfunction(kind, params, body) -> true
    | Llet (_, _, _, _) as lam when check_recursive_recordwith idlist lam ->
        true
    | Llet(str, id, arg, body) ->
        check idlist arg && check (add_let id arg idlist) body
    | Lletrec(bindings, body) ->
        let idlist' = add_letrec bindings idlist in
        List.for_all (fun (id, arg) -> check idlist' arg) bindings &&
        check idlist' body
    | Lprim(Pmakeblock(tag, mut), args) ->
        List.for_all (check idlist) args
    | Lprim(Pmakearray(Paddrarray|Pintarray), args) ->
        List.for_all (check idlist) args
    | Lsequence (lam1, lam2) -> check idlist lam1 && check idlist lam2
    | Levent (lam, _) -> check idlist lam
    | lam ->
        let fv = free_variables lam in
        not (List.exists (fun id -> IdentSet.mem id fv) idlist)

  and add_let id arg idlist =
    let fv = free_variables arg in
    if List.exists (fun id -> IdentSet.mem id fv) idlist
    then id :: idlist
    else idlist

  and add_letrec bindings idlist =
    List.fold_right (fun (id, arg) idl -> add_let id arg idl)
                    bindings idlist

  (* reverse-engineering the code generated by transl_record case 2 *)
  and check_recursive_recordwith idlist = function
    | Llet (Strict, id1, Lprim (Pccall prim, [e1]), body) ->
       prim = prim_obj_dup && check_top idlist e1
       && check_recordwith_updates idlist id1 body
    | _ -> false

  and check_recordwith_updates idlist id1 = function
    | Lsequence (Lprim ((Psetfield _ | Psetfloatfield _), [Lvar id2; e1]), cont)
        -> id2 = id1 && check idlist e1
           && check_recordwith_updates idlist id1 cont
    | Lvar id2 -> id2 = id1
    | _ -> false

  in check_top idlist lam

(* To propagate structured constants *)

exception Not_constant

let extract_constant = function
    Lconst sc -> sc
  | _ -> raise Not_constant

let extract_float = function
    Const_base(Const_float f) -> f
  | _ -> fatal_error "Translcore.extract_float"

(* To find reasonable names for let-bound and lambda-bound idents *)

let rec name_pattern default = function
    [] -> Ident.create default
  | (p, e) :: rem ->
      match p.pat_desc with
        Tpat_var id -> id
      | Tpat_alias(p, id) -> id
      | _ -> name_pattern default rem

(* Push the default values under the functional abstractions *)

let rec push_defaults loc bindings pat_expr_list partial =
  match pat_expr_list with
    [pat, ({exp_desc = Texp_function(pl,partial)} as exp)] ->
      let pl = push_defaults exp.exp_loc bindings pl partial in
      [pat, {exp with exp_desc = Texp_function(pl, partial)}]
  | [pat, {exp_desc = Texp_let
             (Default, cases, ({exp_desc = Texp_function _} as e2))}] ->
      push_defaults loc (cases :: bindings) [pat, e2] partial
  | [pat, exp] ->
      let exp =
        List.fold_left
          (fun exp cases ->
            {exp with exp_desc = Texp_let(Nonrecursive, cases, exp)})
          exp bindings
      in
      [pat, exp]
  | (pat, exp) :: _ when bindings <> [] ->
      let param = name_pattern "param" pat_expr_list in
      let exp =
        { exp with exp_loc = loc; exp_desc =
          Texp_match
            ({exp with exp_type = pat.pat_type; exp_desc =
              Texp_ident (Path.Pident param,
                          {val_type = pat.pat_type; val_kind = Val_reg},
			  ref FA_none)},
             pat_expr_list, partial) }
      in
      push_defaults loc bindings
        [{pat with pat_desc = Tpat_var param}, exp] Total
  | _ ->
      pat_expr_list

(* Insertion of debugging events *)

let event_before exp lam = match lam with
| Lstaticraise (_,_) -> lam
| _ ->
  if !Clflags.debug
  then Levent(lam, {lev_loc = exp.exp_loc;
                    lev_kind = Lev_before;
                    lev_repr = None;
                    lev_env = Env.summary exp.exp_env})
  else lam

let event_after exp lam =
  if !Clflags.debug
  then Levent(lam, {lev_loc = exp.exp_loc;
                    lev_kind = Lev_after exp.exp_type;
                    lev_repr = None;
                    lev_env = Env.summary exp.exp_env})
  else lam

let event_function exp lam =
  if !Clflags.debug then
    let repr = Some (ref 0) in
    let (info, body) = lam repr in
    (info,
     Levent(body, {lev_loc = exp.exp_loc;
                   lev_kind = Lev_function;
                   lev_repr = repr;
                   lev_env = Env.summary exp.exp_env}))
  else
    lam None

let primitive_is_ccall = function
  (* Determine if a primitive is a Pccall or will be turned later into
     a C function call that may raise an exception *)
  | Pccall _ | Pstringrefs | Pstringsets | Parrayrefs _ | Parraysets _ |
    Pbigarrayref _ | Pbigarrayset _ -> true
  | _ -> false

(* Assertions *)

let assert_failed loc =
  (* [Location.get_pos_info] is too expensive *)
  let fname = match loc.Location.loc_start.Lexing.pos_fname with
              | "" -> !Location.input_name
              | x -> x
  in
  let pos = loc.Location.loc_start in
  let line = pos.Lexing.pos_lnum in
  let char = pos.Lexing.pos_cnum - pos.Lexing.pos_bol in
  Lprim(Praise, [Lprim(Pmakeblock(0, Immutable),
          [transl_path Predef.path_assert_failure;
           Lconst(Const_block(0,
              [Const_base(Const_string fname);
               Const_base(Const_int line);
               Const_base(Const_int char)]))])])
;;

let assert_exception loc ecomp =
  (* [Location.get_pos_info] is too expensive *)
  let fname = match loc.Location.loc_start.Lexing.pos_fname with
              | "" -> !Location.input_name
              | x -> x
  in
  let pos = loc.Location.loc_start in
  let line = pos.Lexing.pos_lnum in
  let char = pos.Lexing.pos_cnum - pos.Lexing.pos_bol in
  
  let id = Ident.create "exn" in
  Ltrywith(ecomp, id,
	   Lprim(Praise, [Lprim(Pmakeblock(0, Immutable),
                   [transl_path Predef.path_assert_exception;
		    Lprim(Pmakeblock(0, Immutable),
			  [Lvar id;
			   Lconst(Const_block(0,
				      [Const_base(Const_string fname);
				       Const_base(Const_int line);
				       Const_base(Const_int char)]))])])]))
;;

let path_of_runtime_type_declaration env p =
  if not (List.mem p Predef.builtin_types) then p
  else
    (* FIXME typecore has the same code *)
    let redirect_to_builtintypes = function
      | Path.Pident id -> 
  	  let lid = 
	    if not !Clflags.nobuiltintypes then
	      Longident.Ldot (Longident.Lident "Builtintypes", 
			      Ident.name id)
	    else begin (* inside builtintypes.ml *)
	      Longident.Lident (Ident.name id)
	    end
	  in
	  begin try
	    fst (Env.lookup_value lid env)
	  with
	  | Not_found ->
	      Format.fprintf Format.err_formatter 
		"Fatal error: failed to resolve type %a in builtintypes.ml@."
		Printtyp.longident lid;
	      raise Not_found
	  end
      | _ -> assert false
    in
    redirect_to_builtintypes p

let transl_type_declaration env name recdefs decl =
  (* Translation of type declaration *)
  (* We need the current env to find recursive reference inside 
     builtintypes.ml *)
  let rdecl, type_rtype_tbl, dummy_tbl = 
    Typertype.runtime_type_declaration name recdefs decl in
  let dummy_tbl = 
    (* if the path is one of builtin types, 
       it must be redirected to those of builtintypes.ml *)
    List.map (fun (d,p) -> 
      d, path_of_runtime_type_declaration env p) dummy_tbl 
  in
  let overrides = 
    List.map (fun (d,p) -> Obj.repr d, transl_path p) dummy_tbl 
  in
  Metacomp.transl_constant overrides (Obj.repr rdecl)

(* weak table for ident => path recovery in Texp_typedecl *)
module IDPATH = struct
  type t = Ident.t * Path.t
  let equal ((i1 : Ident.t),_) ((i2 : Ident.t),_) = i1 = i2 
  let hash (i,_) = Hashtbl.hash i
end

module IDPATHTBL = Weak.Make(IDPATH)
let id_path_tbl = IDPATHTBL.create 17

(* create the unique identifier associated to a pattern *)
module PATID = struct
  type t = (pattern * string) * Ident.t
  let equal ((p1,n1),_) ((p2,n2),_) = p1 == p2 && n1 = n2
  let hash (pn,_) = Hashtbl.hash pn
end
module PATIDTBL = Weak.Make(PATID)

let pat_id_tbl = PATIDTBL.create 17
let dummy_id = Ident.create "*dummy*"

let make_ident_of_pattern pat name =
  try snd (PATIDTBL.find pat_id_tbl ((pat, name), dummy_id)) with
  | Not_found ->
      let idname =
	match pat.pat_desc with
	| Tpat_var id -> name ^ Ident.name id
	| Tpat_any -> name ^ "_" 
	| _ -> assert false
      in
      let id = Ident.create idname in
      PATIDTBL.add pat_id_tbl ((pat, name), id);
      id

let rec cut n l =
  if n = 0 then ([],l) else
  match l with [] -> failwith "Translcore.cut"
  | a::l -> let (l1,l2) = cut (n-1) l in (a::l1,l2)

(* Translation of expressions *)

let rec transl_exp e =
  let eval_once =
    (* Whether classes for immediate objects must be cached *)
    match e.exp_desc with
      Texp_function _ | Texp_for _ | Texp_while _ -> false
    | _ -> true
  in
  if eval_once then transl_exp0 e else
  Translobj.oo_wrap e.exp_env true transl_exp0 e

and transl_exp0 e =
  match e.exp_desc with
    Texp_ident(path, {val_kind = Val_prim p}, _) ->
      let public_send = p.prim_name = "%send" in
      if public_send || p.prim_name = "%sendself" then
        let kind = if public_send then Public else Self in
	let obj = Ident.create "obj" and meth = Ident.create "meth" in
	Lfunction(Curried, [obj; meth], Lsend(kind, Lvar meth, Lvar obj, []))
      else if p.prim_name = "%sendcache" then
	let obj = Ident.create "obj" and meth = Ident.create "meth" in
        let cache = Ident.create "cache" and pos = Ident.create "pos" in
	Lfunction(Curried, [obj; meth; cache; pos],
                  Lsend(Cached, Lvar meth, Lvar obj, [Lvar cache; Lvar pos]))
      else
	transl_primitive p
  | Texp_ident(path, {val_kind = Val_anc _}, _) ->
      raise(Error(e.exp_loc, Free_super_var))
  | Texp_ident(path, ({val_kind = Val_reg | Val_self _} as vdesc), instref) ->
      let path = (* path conversion for typedecl *)
	match path with
	| Pident id -> 
	    begin try
	      let _,path = IDPATHTBL.find id_path_tbl (id,path (* dummy *)) in
	      path
	    with
	    | Not_found -> path
	    end
	| _ -> path 
      in
      begin match vdesc.val_type.desc with
      | Tkonst (_,_) | Toverload _ ->
	  begin try
	    transl_flow_application e.exp_env path vdesc e.exp_type !instref
	  with
	  | Typertype.Error (_, Typertype.Unsupported) ->
	      raise (Error (e.exp_loc, Unsupported_type_constructor))
	  end
      | _ -> transl_path path
      end
  | Texp_ident _ -> fatal_error "Translcore.transl_exp: bad Texp_ident"
  | Texp_constant cst ->
      Lconst(Const_base cst)
  | Texp_let(rec_flag, pat_expr_list, body) ->
      transl_let rec_flag pat_expr_list (event_before body (transl_exp body))
  | Texp_function (pat_expr_list, partial) ->
      let ((kind, params), body) =
        event_function e
          (function repr ->
            let pl = push_defaults e.exp_loc [] pat_expr_list partial in
            transl_function e.exp_loc !Clflags.native_code repr partial pl)
      in
      Lfunction(kind, params, body)
  | Texp_apply({exp_desc = Texp_ident(path, {val_kind = Val_prim p}, _)}, args)
    when List.length args >= p.prim_arity
    && List.for_all (fun (arg,_) -> arg <> None) args ->
      let args, args' = cut p.prim_arity args in
      let wrap f =
        event_after e (if args' = [] then f else transl_apply f args') in
      let wrap0 f =
        if args' = [] then f else wrap f in
      let args = List.map (function Some x, _ -> x | _ -> assert false) args in
      let argl = transl_list args in
      let public_send = p.prim_name = "%send"
        || not !Clflags.native_code && p.prim_name = "%sendcache"in
      if public_send || p.prim_name = "%sendself" then
        let kind = if public_send then Public else Self in
	let obj = List.hd argl in
	wrap (Lsend (kind, List.nth argl 1, obj, []))
      else if p.prim_name = "%sendcache" then
        match argl with [obj; meth; cache; pos] ->
          wrap (Lsend(Cached, meth, obj, [cache; pos]))
        | _ -> assert false
      else begin
        let prim = transl_prim p args in
        match (prim, args) with
          (Praise, [arg1]) ->
            wrap0 (Lprim(Praise, [event_after arg1 (List.hd argl)]))
        | (_, _) ->
            let p = Lprim(prim, argl) in
            if primitive_is_ccall prim then wrap p else wrap0 p
      end
  | Texp_apply(funct, oargs) ->
      event_after e (transl_apply (transl_exp funct) oargs)
  | Texp_match({exp_desc = Texp_tuple argl}, pat_expr_list, partial) ->
      Matching.for_multiple_match e.exp_loc
        (transl_list argl) (transl_cases pat_expr_list) partial
  | Texp_match(arg, pat_expr_list, partial) ->
      Matching.for_function e.exp_loc None
        (transl_exp arg) (transl_cases pat_expr_list) partial
  | Texp_try(body, pat_expr_list) ->
      let id = name_pattern "exn" pat_expr_list in
      Ltrywith(transl_exp body, id,
               Matching.for_trywith (Lvar id) (transl_cases pat_expr_list))
  | Texp_tuple el ->
      let ll = transl_list el in
      begin try
        Lconst(Const_block(0, List.map extract_constant ll))
      with Not_constant ->
        Lprim(Pmakeblock(0, Immutable), ll)
      end
  | Texp_construct(cstr, args) ->
      let ll = transl_list args in
      begin match cstr.cstr_tag with
        Cstr_constant n ->
          Lconst(Const_pointer n)
      | Cstr_block n ->
          begin try
            Lconst(Const_block(n, List.map extract_constant ll))
          with Not_constant ->
            Lprim(Pmakeblock(n, Immutable), ll)
          end
      | Cstr_exception path ->
          Lprim(Pmakeblock(0, Immutable), transl_path path :: ll)
      end
  | Texp_variant(l, arg) ->
      let tag = Btype.hash_variant l in
      begin match arg with
        None -> Lconst(Const_pointer tag)
      | Some arg ->
          let lam = transl_exp arg in
          try
            Lconst(Const_block(0, [Const_base(Const_int tag);
                                   extract_constant lam]))
          with Not_constant ->
            Lprim(Pmakeblock(0, Immutable),
                  [Lconst(Const_base(Const_int tag)); lam])
      end
  | Texp_record ((lbl1, _) :: _ as lbl_expr_list, opt_init_expr) ->
      transl_record lbl1.lbl_all lbl1.lbl_repres lbl_expr_list opt_init_expr
  | Texp_record ([], _) ->
      fatal_error "Translcore.transl_exp: bad Texp_record"
  | Texp_field(arg, lbl) ->
      let access =
        match lbl.lbl_repres with
          Record_regular -> Pfield lbl.lbl_pos
        | Record_float -> Pfloatfield lbl.lbl_pos in
      Lprim(access, [transl_exp arg])
  | Texp_setfield(arg, lbl, newval) ->
      let access =
        match lbl.lbl_repres with
          Record_regular -> Psetfield(lbl.lbl_pos, maybe_pointer newval)
        | Record_float -> Psetfloatfield lbl.lbl_pos in
      Lprim(access, [transl_exp arg; transl_exp newval])
  | Texp_array expr_list ->
      let kind = array_kind e in
      let ll = transl_list expr_list in
      begin try
        (* Deactivate constant optimization if array is small enough *)
        if List.length ll <= 4 then raise Not_constant;
        let cl = List.map extract_constant ll in
        let master =
          match kind with
          | Paddrarray | Pintarray ->        
              Lconst(Const_block(0, cl))
          | Pfloatarray ->
              Lconst(Const_float_array(List.map extract_float cl))
          | Pgenarray ->
              raise Not_constant in             (* can this really happen? *)
        Lprim(Pccall prim_obj_dup, [master])
      with Not_constant ->
        Lprim(Pmakearray kind, ll)
      end
  | Texp_ifthenelse(cond, ifso, Some ifnot) ->
      Lifthenelse(transl_exp cond,
                  event_before ifso (transl_exp ifso),
                  event_before ifnot (transl_exp ifnot))
  | Texp_ifthenelse(cond, ifso, None) ->
      Lifthenelse(transl_exp cond,
                  event_before ifso (transl_exp ifso),
                  lambda_unit)
  | Texp_sequence(expr1, expr2) ->
      Lsequence(transl_exp expr1, event_before expr2 (transl_exp expr2))
  | Texp_while(cond, body) ->
      Lwhile(transl_exp cond, event_before body (transl_exp body))
  | Texp_for(param, low, high, dir, body) ->
      Lfor(param, transl_exp low, transl_exp high, dir,
           event_before body (transl_exp body))
  | Texp_when(cond, body) ->
      event_before cond
        (Lifthenelse(transl_exp cond, event_before body (transl_exp body),
                     staticfail))
  | Texp_send(expr, met) ->
      let obj = transl_exp expr in
      let lam =
        match met with 
          Tmeth_val id -> Lsend (Self, Lvar id, obj, [])
        | Tmeth_name nm ->
            let (tag, cache) = Translobj.meth obj nm in
	    let kind = if cache = [] then Public else Cached in
            Lsend (kind, tag, obj, cache)
      in
      event_after e lam
  | Texp_new (cl, _) ->
      Lapply(Lprim(Pfield 0, [transl_path cl]), [lambda_unit])
  | Texp_instvar(path_self, path) ->
      Lprim(Parrayrefu Paddrarray, [transl_path path_self; transl_path path])
  | Texp_setinstvar(path_self, path, expr) ->
      transl_setinstvar (transl_path path_self) path expr
  | Texp_override(path_self, modifs) ->
      let cpy = Ident.create "copy" in
      Llet(Strict, cpy,
           Lapply(Translobj.oo_prim "copy", [transl_path path_self]),
           List.fold_right
             (fun (path, expr) rem ->
                Lsequence(transl_setinstvar (Lvar cpy) path expr, rem))
             modifs
             (Lvar cpy))
  | Texp_letmodule(id, modl, body) ->
      Llet(Strict, id, !transl_module Tcoerce_none None modl, transl_exp body)
  | Texp_assert (cond) ->
      if !Clflags.noassert
      then lambda_unit
      else Lifthenelse (transl_exp cond, lambda_unit, assert_failed e.exp_loc)
  | Texp_assertfalse -> assert_failed e.exp_loc
  | Texp_assertexception (e) ->
      if !Clflags.noassert
      then transl_exp e (* unlike assert, e may often contain side effects *)
      else assert_exception e.exp_loc (transl_exp e)
  | Texp_lazy e ->
      let fn = Lfunction (Curried, [Ident.create "param"], transl_exp e) in
      Lprim(Pmakeblock(Config.lazy_tag, Immutable), [fn])
  | Texp_object (cs, cty, meths) ->
      let cl = Ident.create "class" in
      !transl_object cl meths
        { cl_desc = Tclass_structure cs;
          cl_loc = e.exp_loc;
          cl_type = Tcty_signature cty;
          cl_env = e.exp_env }
  | Texp_rtype ty -> 
      begin try
	match transl_type_exprs e.exp_env [] [ty] with
	| [lam] -> lam
	| _ -> assert false
      with
      | Typertype.Error (loc, Typertype.Unsupported) ->
	  raise (Error (loc, Unsupported_type_constructor))
      end
  | Texp_typedecl path ->
      (* This is a very special case. It happens only in the compilation
	 of stdlib/builtintypes.ml, where we have to build the type
	 declaration code *)
      transl_type_declaration e.exp_env (Path.name path) [] 
	(Env.find_type path Env.initial)
  | Texp_generic cases ->
      (* FIXME *)
      lambda_unit
      

and transl_list expr_list =
  List.map transl_exp expr_list

and transl_cases pat_expr_list =
  List.map
    (fun (pat, expr) -> (pat, event_before expr (transl_exp expr)))
    pat_expr_list

and transl_tupled_cases patl_expr_list =
  List.map (fun (patl, expr) -> (patl, transl_exp expr)) patl_expr_list

and transl_apply lam sargs =
  let lapply funct args =
    match funct with
      Lsend(k, lmet, lobj, largs) ->
        Lsend(k, lmet, lobj, largs @ args)
    | Levent(Lsend(k, lmet, lobj, largs), _) ->
        Lsend(k, lmet, lobj, largs @ args)
    | Lapply(lexp, largs) ->
        Lapply(lexp, largs @ args)
    | lexp ->
        Lapply(lexp, args)
  in
  let rec build_apply lam args = function
      (None, optional) :: l ->
        let defs = ref [] in
        let protect name lam =
          match lam with
            Lvar _ | Lconst _ -> lam
          | _ ->
              let id = Ident.create name in
              defs := (id, lam) :: !defs;
              Lvar id
        in
        let args, args' =
          if List.for_all (fun (_,opt) -> opt = Optional) args then [], args
          else args, [] in
        let lam =
          if args = [] then lam else lapply lam (List.rev_map fst args) in
        let handle = protect "func" lam
        and l = List.map (fun (arg, opt) -> may_map (protect "arg") arg, opt) l
        and id_arg = Ident.create "param" in
        let body =
          match build_apply handle ((Lvar id_arg, optional)::args') l with
            Lfunction(Curried, ids, lam) ->
              Lfunction(Curried, id_arg::ids, lam)
          | Levent(Lfunction(Curried, ids, lam), _) ->
              Lfunction(Curried, id_arg::ids, lam)
          | lam ->
              Lfunction(Curried, [id_arg], lam)
        in
        List.fold_left
          (fun body (id, lam) -> Llet(Strict, id, lam, body))
          body !defs
    | (Some arg, optional) :: l ->
        build_apply lam ((arg, optional) :: args) l
    | [] ->
        lapply lam (List.rev_map fst args)
  in
  build_apply lam [] (List.map (fun (x,o) -> may_map transl_exp x, o) sargs)

and transl_function loc untuplify_fn repr partial pat_expr_list =
  match pat_expr_list with
    [pat, ({exp_desc = Texp_function(pl,partial')} as exp)] ->
      let param = name_pattern "param" pat_expr_list in
      let ((_, params), body) =
        transl_function exp.exp_loc false repr partial' pl in
      ((Curried, param :: params),
       Matching.for_function loc None (Lvar param) [pat, body] partial)
  | ({pat_desc = Tpat_tuple pl}, _) :: _ when untuplify_fn ->
      begin try
        let size = List.length pl in
        let pats_expr_list =
          List.map
            (fun (pat, expr) -> (Matching.flatten_pattern size pat, expr))
            pat_expr_list in
        let params = List.map (fun p -> Ident.create "param") pl in
        ((Tupled, params),
         Matching.for_tupled_function loc params
           (transl_tupled_cases pats_expr_list) partial)
      with Matching.Cannot_flatten ->
        let param = name_pattern "param" pat_expr_list in
        ((Curried, [param]),
         Matching.for_function loc repr (Lvar param)
           (transl_cases pat_expr_list) partial)
      end
  | _ ->
      let param = name_pattern "param" pat_expr_list in
      ((Curried, [param]),
       Matching.for_function loc repr (Lvar param)
         (transl_cases pat_expr_list) partial)

and transl_let rec_flag pat_expr_list body =
  match rec_flag with
    Nonrecursive | Default ->
      let rec transl = function
        [] ->
          body
      | (pat, expr) :: rem ->
	  let lam = transl_flow_abstraction pat transl_exp expr in
          Matching.for_let pat.pat_loc lam pat (transl rem)
      in transl pat_expr_list
  | Recursive ->
      let idlist =
        List.map
          (fun (pat, expr) ->
            match pat.pat_desc with
              Tpat_var id -> id
            | _ -> raise(Error(pat.pat_loc, Illegal_letrec_pat)))
        pat_expr_list in
      let transl_case (pat, expr) id =
        let lam = transl_flow_abstraction pat transl_exp expr in
        if not (check_recursive_lambda idlist lam) then
          raise(Error(expr.exp_loc, Illegal_letrec_expr));
        (id, lam) in
      Lletrec(List.map2 transl_case pat_expr_list idlist, body)

and transl_setinstvar self var expr =
  Lprim(Parraysetu (if maybe_pointer expr then Paddrarray else Pintarray),
                    [self; transl_path var; transl_exp expr])

and transl_record all_labels repres lbl_expr_list opt_init_expr =
  (* Determine if there are "enough" new fields *)
  if 3 + 2 * List.length lbl_expr_list >= Array.length all_labels
  then begin
    (* Allocate new record with given fields (and remaining fields
       taken from init_expr if any *)
    let lv = Array.create (Array.length all_labels) staticfail in
    let init_id = Ident.create "init" in
    begin match opt_init_expr with
      None -> ()
    | Some init_expr ->
        for i = 0 to Array.length all_labels - 1 do
          let access =
            match all_labels.(i).lbl_repres with
              Record_regular -> Pfield i
            | Record_float -> Pfloatfield i in
          lv.(i) <- Lprim(access, [Lvar init_id])
        done
    end;
    List.iter
      (fun (lbl, expr) -> lv.(lbl.lbl_pos) <- transl_exp expr)
      lbl_expr_list;
    let ll = Array.to_list lv in
    let mut =
      if List.exists (fun (lbl, expr) -> lbl.lbl_mut = Mutable) lbl_expr_list
      then Mutable
      else Immutable in
    let lam =
      try
        if mut = Mutable then raise Not_constant;
        let cl = List.map extract_constant ll in
        match repres with
          Record_regular -> Lconst(Const_block(0, cl))
        | Record_float ->
            Lconst(Const_float_array(List.map extract_float cl))
      with Not_constant ->
        match repres with
          Record_regular -> Lprim(Pmakeblock(0, mut), ll)
        | Record_float -> Lprim(Pmakearray Pfloatarray, ll) in
    begin match opt_init_expr with
      None -> lam
    | Some init_expr -> Llet(Strict, init_id, transl_exp init_expr, lam)
    end
  end else begin
    (* Take a shallow copy of the init record, then mutate the fields
       of the copy *)
    (* If you change anything here, you will likely have to change
       [check_recursive_recordwith] in this file. *)
    let copy_id = Ident.create "newrecord" in
    let rec update_field (lbl, expr) cont =
      let upd =
        match lbl.lbl_repres with
          Record_regular -> Psetfield(lbl.lbl_pos, maybe_pointer expr)
        | Record_float -> Psetfloatfield lbl.lbl_pos in
      Lsequence(Lprim(upd, [Lvar copy_id; transl_exp expr]), cont) in
    begin match opt_init_expr with
      None -> assert false
    | Some init_expr ->
        Llet(Strict, copy_id,
             Lprim(Pccall prim_obj_dup, [transl_exp init_expr]),
             List.fold_right update_field lbl_expr_list (Lvar copy_id))
    end
  end

(* Generic stuffs *)

and transl_type_exprs env vartbl tys = 
  let rtys, type_rtype_tbl, decl_path_tbl = 
    Typertype.runtime_type_exprs tys 
  in
  (* type abstracted variables must be replaced by identifiers bound
     in [vartbl]. *)
  (* dummy type declarations must be replaced by identifiers bound
     in [decl_path_tbl]. Note: we must use special paths for builtin 
     data types. *)
  let decl_path_tbl =
    List.map 
      (fun (decl, path) -> decl, path_of_runtime_type_declaration env path)
      decl_path_tbl
  in
  let overrides_paths =
    List.fold_left (fun st (ty,rt) ->
      match ty.desc with
      | Tpath p -> (Obj.repr rt, transl_path p) :: st
      | _ -> st) [] type_rtype_tbl
  in
  let overrides_type_decls =
    List.map (fun (decl,path) -> Obj.repr decl, transl_path path) 
      decl_path_tbl 
  in
  let overrides = 
    List.fold_left (fun st (ty,rt) ->
      try 
	(* retrieve the original type variable, in order to recover
	   the linkage to the generalization *)
	let t = List.assq ty vartbl in
	let id = Gtype.find_ident_of_type_variable t in
	(Obj.repr rt, transl_path (Pident id)) :: st
      with
      | Not_found -> st) (overrides_paths @ overrides_type_decls) 
      type_rtype_tbl
  in
  List.map (fun rty -> Metacomp.transl_constant overrides (Obj.repr rty)) rtys
(*
  let stys, path_lid_tbl, tabst_ids = Typertype.to_core_types vartbl tys in
  let lid_path_tbl = List.map (fun (p,lid) -> (lid,p)) path_lid_tbl in
  let ident_path_tbl = 
    List.map (fun (lid,p) -> 
      match lid with
      | Longident.Lident name -> Ident.create name, p 
      | _ -> assert false) lid_path_tbl
  in
  let sexps = 
    List.map (Typertype.value_of_type (fun lid ->
      try List.assoc lid lid_path_tbl with Not_found -> 
	assert false)) stys
  in
  (* add identifiers of type abstractions to the typing env, so that
     they can be typed correctly *)
  let vdesc = { val_type= Typertype.get_rtype_type ();
		val_kind= Val_reg } in
  let env' = List.fold_left (fun env id -> 
    Env.add_value id vdesc env) env tabst_ids
  in
  let vdesc = { val_type= Typertype.get_rtype_type_declaration ();
		val_kind= Val_reg }
  in
  let env'' = List.fold_left (fun env (id, p) ->
    Env.add_value id vdesc env) env' ident_path_tbl
  in
  let exps = 
    List.map (fun sexp -> 
      Typecore.type_expect env'' (Kset.empty ()) sexp 
	(Typertype.get_rtype_type ())) 
      sexps
  in
  List.iter (fun (id,path) -> 
    IDPATHTBL.add id_path_tbl (id,path)) ident_path_tbl;
  List.map transl_exp exps
*)

and transl_flow env flow = 
  let transl_flow env flow =
    let visited = ref [] in
    let loops = ref [] in
    let rec find_loop flow = 
      match flow with
      | Floop fref -> 
  	  if not (List.memq !fref !visited) then assert false
	  else begin
  	    if not (List.mem_assq !fref !loops) then
  	      loops := (!fref, Ident.create "loop") :: !loops 
	  end				
      | _ ->
  	visited := flow :: !visited;
  	match flow with
  	| Ftype _ -> ()
  	| Fkonst frecord -> List.iter (fun (_,flow) -> find_loop flow) frecord
  	| Foverload (_,flow) -> find_loop flow
  	| _ -> assert false
    in
    find_loop flow;

    let make_block tag ll =
      try
        Lconst (Const_block (tag, List.map extract_constant ll))
      with
        _ -> Lprim (Pmakeblock (tag, Immutable), ll)
    in
  
    let rec transl flow = 
      try 
        let id = List.assq flow !loops in
        Lletrec ([id, transl_norec flow], Lvar id)
      with
      | Not_found -> transl_norec flow

    and transl_norec = function
      | Ftype typ ->
  	  begin match transl_type_exprs env [] [typ] with
  	  | [lam] -> lam
  	  | _ -> assert false
  	  end
      | Fkonst frecord ->
  	  (* already sorted (?) *)
  	  make_block 0
  	    (List.map (fun (_,sflow) -> transl sflow) frecord)
      | Foverload (pos, Fkonst frecord) ->
  	  make_block 0
  	    (Lconst (Const_base (Const_int pos)) ::
  	     List.map (fun (_,sflow) -> transl sflow) frecord)
      | Foverload _ -> assert false
      | Floop fref ->
	  Lvar (List.assq !fref !loops)
    in
  
    let lam = transl flow in
  (*
    Format.eprintf "FLOW= %a@." Printlambda.lambda lam;
  *)
    lam
  in
  try
    transl_flow env flow
  with
  | e -> Format.eprintf "FLOWERROR: %a@." Gtype.print_flow flow; raise e

and transl_flow_application env path vdesc etyp instinfo =
  match vdesc.val_type.desc with
  | Tkonst ([kelem],_) -> 
      (* special case *)
      let rec match_instinfo = function
	| FA_flow (Fkonst [_,flow]) -> 
	    Lapply (transl_path path, [transl_flow env flow])
	| FA_flow (Floop fref) -> 
	    (* FIXME: this is not a loop, but a case of a link. *) 
(*
	    match_instinfo (FA_flow !fref)
*)
	    assert false
	| FA_flow _ -> assert false
	| FA_konst (p, ke, t) ->
	    begin match t.desc with
	    | Tkonst ([],_) -> assert false
	    | Tkonst ([_],_) ->
		let id = make_ident_of_pattern p "kflow*" in
		let flam = Lvar id in
		Lapply(transl_path path, [Lprim (Pfield 0, [flam])])
	    | Tkonst _ ->
		let pos = Gtype.index_of_flow_record env ke t in
		let id = make_ident_of_pattern p "kfrec*" in
		let flam = Lprim (Pfield pos, [Lvar id]) in
		Lapply(transl_path path, [Lprim (Pfield 0, [flam])])
	    | _ -> assert false
	    end
	| FA_overload (p, ke, t) ->
	    begin match t.desc with
	    | Tkonst ([],_) -> assert false
	    | Tkonst _ ->
		let pos = Gtype.index_of_flow_record env ke t in
		let id = make_ident_of_pattern p "ofrec*" in
		let flam = Lprim (Pfield (pos + 1), [Lvar id]) in
		Lapply(transl_path path, [Lprim (Pfield 0,[flam])])
	    | _ -> assert false
	    end
	| FA_none -> assert false
      in
      match_instinfo instinfo
  | Tkonst (konst,_) -> 
      let rec match_instinfo = function
	| FA_flow (Fkonst _ as flow) -> 
	    Lapply (transl_path path, [transl_flow env flow])
	| FA_flow (Floop fref) -> match_instinfo (FA_flow !fref)
	| FA_flow _ -> assert false
	| FA_konst (p, ke, t) ->
	    begin match t.desc with
	    | Tkonst ([],_) -> assert false
	    | Tkonst ([_],_) ->
		let id = make_ident_of_pattern p "kflow*" in
		let flam = Lvar id in
		Lapply(transl_path path, [flam])
	    | Tkonst _ ->
		let pos = Gtype.index_of_flow_record env ke t in
		let id = make_ident_of_pattern p "kfrec*" in
		let flam = Lprim (Pfield pos, [Lvar id]) in
		Lapply(transl_path path, [flam])
	    | _ -> assert false
	    end
	| FA_overload (p, ke, t) ->
	    begin match t.desc with
	    | Tkonst ([],_) -> assert false
	    | Tkonst _ ->
		let pos = Gtype.index_of_flow_record env ke t in
		let id = make_ident_of_pattern p "ofrec*" in
		let flam = Lprim (Pfield (pos + 1), [Lvar id]) in
		Lapply(transl_path path, [flam])
	    | _ -> assert false
	    end
	| FA_none -> assert false
      in
      match_instinfo instinfo
  | Toverload odesc ->
      let rec match_instinfo = function
        | FA_flow (Foverload (pos, _) as flow) ->
  	    Lapply (Lprim(Pfield pos, [transl_path path]), 
  		    [transl_flow env flow])
        | FA_flow (Floop fref) -> match_instinfo (FA_flow !fref)
        | FA_flow _ -> assert false
        | FA_konst (p, ke, t) ->
  	    begin match t.desc with
  	    | Tkonst ([],_) -> assert false
  	    | Tkonst ([_],_) ->
  		let id = make_ident_of_pattern p "kflow*" in
  		let flam = Lvar id in
  		Lapply(Lprim(Parrayrefu Paddrarray, 
  			     [transl_path path; Lprim (Pfield 0, [flam])]), 
  		       [flam])
  	    | Tkonst _ ->
  		let pos = Gtype.index_of_flow_record env ke t in
  		let id = make_ident_of_pattern p "kfrec*" in
  		let flam = Lprim (Pfield pos, [Lvar id]) in  
  		Lapply(Lprim(Parrayrefu Paddrarray, 
  			     [transl_path path; Lprim (Pfield 0, [flam])]), 
  		       [flam])
  	    | _ -> assert false
  	    end
        | FA_overload (p, ke, t) ->
  	    let pos = Gtype.index_of_flow_record env ke t in
  	    let id = make_ident_of_pattern p "ofrec*" in
  	    let flam = Lprim (Pfield (pos+1), [Lvar id]) in
  	    Lapply(Lprim(Parrayrefu Paddrarray, 
  			 [transl_path path; Lprim (Pfield 0, [flam])]),
  		   [flam])
        | FA_none -> assert false 
      in
      match_instinfo instinfo
  | _ -> assert false
      
and transl_flow_abstraction pat compfunc exp =
  begin match pat.pat_type.desc with
  | Tkonst _ | Toverload _ -> Etype.normalize_type pat.pat_type
  | _ -> ()
  end;
  match pat.pat_type.desc with
  | Tkonst([], t) -> assert false
  | Tkonst([_], t) ->
      let id = make_ident_of_pattern pat "kflow*" in
      Lfunction(Curried, [id], compfunc exp) 
  | Tkonst(konst, t) ->
      let id = make_ident_of_pattern pat "kfrec*" in
      Lfunction(Curried, [id], compfunc exp) 
  | Toverload odesc ->
      begin match exp.exp_desc with
      | Texp_generic cases ->
	  let transl_generic_case compfunc (_,exp) =
	    match exp.exp_type.desc with
	    | Tkonst ([], _) -> assert false
	    | Toverload _ -> assert false
	    | Tkonst _ | _ ->
		let id = make_ident_of_pattern pat "ofrec*" in
		Lfunction(Curried, [id], compfunc exp)
	  in
	  Lprim (Pmakeblock (0, Immutable), 
		 List.map (transl_generic_case compfunc) cases)
      | _ -> assert false
      end
  | _ -> compfunc exp

let transl_eval e pat = transl_flow_abstraction pat transl_exp e

(* Wrapper for class compilation *)

(*
let transl_exp = transl_exp_wrap

let transl_let rec_flag pat_expr_list body =
  match pat_expr_list with
    [] -> body
  | (_, expr) :: _ ->
      Translobj.oo_wrap expr.exp_env false
        (transl_let rec_flag pat_expr_list) body
*)

(* Compile an exception definition *)

let transl_exception id path decl =
  let name =
    match path with
      None -> Ident.name id
    | Some p -> Path.name p in
  Lprim(Pmakeblock(0, Immutable), [Lconst(Const_base(Const_string name))])

(* Error report *)

open Format

let report_error ppf = function
  | Illegal_letrec_pat ->
      fprintf ppf
        "Only variables are allowed as left-hand side of `let rec'"
  | Illegal_letrec_expr ->
      fprintf ppf
        "This kind of expression is not allowed as right-hand side of `let rec'"
  | Free_super_var ->
      fprintf ppf
        "Ancestor names can only be used to select inherited methods"
  | Unsupported_type_constructor ->
      fprintf ppf
        "Type contains unsupported constructor as a run-time type"
