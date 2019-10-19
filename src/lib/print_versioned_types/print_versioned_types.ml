open Core_kernel
open Ppxlib

(* print_versioned_types.ml -- print representation of each versioned type Stable.Vn.[T.].t 
   each type has `deriving version`; this is a custom deriver for that
*)

let deriver = "version"

let contains_deriving_bin_io (attrs : attributes) =
  match
    List.find attrs ~f:(fun ({txt; _}, _) -> String.equal txt "deriving")
  with
  | Some (_deriving, payload) -> (
    match payload with
    (* always have a tuple here; any deriving items are in addition to `version` *)
    | PStr [{pstr_desc= Pstr_eval ({pexp_desc= Pexp_tuple items; _}, _); _}] ->
        List.exists items ~f:(fun item ->
            match item with
            | {pexp_desc= Pexp_ident {txt= Lident "bin_io"; _}; _} ->
                true
            | _ ->
                false )
    | _ ->
        false )
  | None ->
      (* unreachable *)
      false

(* singleton attribute *)
let just_bin_io =
  let loc = Location.none in
  [ ( {txt= "deriving"; loc}
    , PStr
        [ { pstr_desc=
              Pstr_eval
                ( { pexp_desc= Pexp_ident {txt= Lident "bin_io"; loc}
                  ; pexp_loc= loc
                  ; pexp_attributes= [] }
                , [] )
          ; pstr_loc= loc } ] ) ]

(* filter attributes from types, except for bin_io, don't care about changes to others *)
let filter_type_decls_attrs type_decl =
  (* retain `deriving bin_io` *)
  let attrs = type_decl.ptype_attributes in
  let ptype_attributes =
    if contains_deriving_bin_io attrs then just_bin_io else []
  in
  {type_decl with ptype_attributes}

(* convert type_decls to structure item so we can print it *)
let type_decls_to_stri type_decls =
  (* alas, type derivers aren't passed the rec flag, use a default *)
  {pstr_desc= Pstr_type (Ast.Nonrecursive, type_decls); pstr_loc= Location.none}

(* prints module_path:type_definition *)
let print_type ~options:_ ~path type_decls =
  let path_len = List.length path in
  List.iteri path ~f:(fun i s ->
      printf "%s" s ;
      if i < path_len - 1 then printf "." ) ;
  printf ":%!" ;
  let type_decls_filtered_attrs =
    List.map type_decls ~f:filter_type_decls_attrs
  in
  let stri = type_decls_to_stri type_decls_filtered_attrs in
  Pprintast.structure_item Format.std_formatter stri ;
  Format.print_flush () ;
  printf "\n%!" ;
  []

let () = Ppx_deriving.(register (create deriver ~type_decl_str:print_type ()))

let () = Ppxlib.Driver.standalone ()
