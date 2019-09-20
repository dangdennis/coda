open Core_kernel
open Coda_base
open Coda_state
open Coda_transition
open Frontier_base

module Node = struct
  type t =
    {breadcrumb: Breadcrumb.t; successor_hashes: State_hash.t list; length: int}
  [@@deriving sexp, fields]

  type display =
    { length: int
    ; state_hash: string
    ; blockchain_state: Blockchain_state.display
    ; consensus_state: Consensus.Data.Consensus_state.display }
  [@@deriving yojson]

  let equal node1 node2 = Breadcrumb.equal node1.breadcrumb node2.breadcrumb

  let hash node = Breadcrumb.hash node.breadcrumb

  let compare node1 node2 =
    Breadcrumb.compare node1.breadcrumb node2.breadcrumb

  let name t = Breadcrumb.name t.breadcrumb

  let display t =
    let {Breadcrumb.state_hash; consensus_state; blockchain_state; _} =
      Breadcrumb.display t.breadcrumb
    in
    {state_hash; blockchain_state; length= t.length; consensus_state}
end

(* Invariant: The path from the root to the tip inclusively, will be max_length *)
type t =
  { root_ledger: Ledger.Db.t
  ; mutable root: State_hash.t
  ; mutable best_tip: State_hash.t
  ; mutable hash: Frontier_hash.t
  ; logger: Logger.t
  ; table: Node.t State_hash.Table.t
  ; consensus_local_state: Consensus.Data.Local_state.t
  ; max_length: int }

let create ~logger ~root_data ~root_ledger ~base_hash ~consensus_local_state
    ~max_length =
  let open Root_data in
  let root_hash =
    External_transition.Validated.state_hash root_data.transition
  in
  let root_protocol_state =
    External_transition.Validated.protocol_state root_data.transition
  in
  let root_blockchain_state =
    Protocol_state.blockchain_state root_protocol_state
  in
  let root_blockchain_state_ledger_hash =
    Blockchain_state.snarked_ledger_hash root_blockchain_state
  in
  assert (
    Frozen_ledger_hash.equal
      (Frozen_ledger_hash.of_ledger_hash (Ledger.Db.merkle_root root_ledger))
      root_blockchain_state_ledger_hash ) ;
  let root_breadcrumb =
    Breadcrumb.create root_data.transition root_data.staged_ledger
  in
  let root_node =
    {Node.breadcrumb= root_breadcrumb; successor_hashes= []; length= 0}
  in
  let table = State_hash.Table.of_alist_exn [(root_hash, root_node)] in
  Coda_metrics.(Gauge.set Transition_frontier.active_breadcrumbs 1.0) ;
  { logger
  ; root_ledger
  ; root= root_hash
  ; best_tip= root_hash
  ; hash= base_hash
  ; table
  ; consensus_local_state
  ; max_length }

let close _t =
  Coda_metrics.(Gauge.set Transition_frontier.active_breadcrumbs 0.0) ;
  failwith
    "TODO: detach root breadcrumb staged ledger ledger mask from root snarked \
     ledger database"

let consensus_local_state {consensus_local_state; _} = consensus_local_state

let set_hash_unsafe t (`I_promise_this_is_safe hash) = t.hash <- hash

let hash t = t.hash

let all_breadcrumbs t =
  List.map (Hashtbl.data t.table) ~f:(fun {breadcrumb; _} -> breadcrumb)

let find t hash =
  let open Option.Let_syntax in
  let%map node = Hashtbl.find t.table hash in
  node.breadcrumb

let find_exn t hash =
  let node = Hashtbl.find_exn t.table hash in
  node.breadcrumb

let root t = find_exn t t.root

let best_tip t = find_exn t t.best_tip

let root_data t =
  let open Root_data in
  let root = root t in
  { transition= Breadcrumb.validated_transition root
  ; staged_ledger= Breadcrumb.staged_ledger root }

let equal t1 t2 =
  let sort_breadcrumbs = List.sort ~compare:Breadcrumb.compare in
  let equal_breadcrumb breadcrumb1 breadcrumb2 =
    let open Breadcrumb in
    let open Option.Let_syntax in
    let get_successor_nodes frontier breadcrumb =
      let%map node = Hashtbl.find frontier.table @@ state_hash breadcrumb in
      Node.successor_hashes node
    in
    equal breadcrumb1 breadcrumb2
    && State_hash.equal (parent_hash breadcrumb1) (parent_hash breadcrumb2)
    && (let%bind successors1 = get_successor_nodes t1 breadcrumb1 in
        let%map successors2 = get_successor_nodes t2 breadcrumb2 in
        List.equal State_hash.equal
          (successors1 |> List.sort ~compare:State_hash.compare)
          (successors2 |> List.sort ~compare:State_hash.compare))
       |> Option.value_map ~default:false ~f:Fn.id
  in
  List.equal equal_breadcrumb
    (all_breadcrumbs t1 |> sort_breadcrumbs)
    (all_breadcrumbs t2 |> sort_breadcrumbs)

let max_length {max_length; _} = max_length

let root_length t = (Hashtbl.find_exn t.table t.root).length

let successor_hashes t hash =
  let node = Hashtbl.find_exn t.table hash in
  node.successor_hashes

let rec successor_hashes_rec t hash =
  List.bind (successor_hashes t hash) ~f:(fun succ_hash ->
      succ_hash :: successor_hashes_rec t succ_hash )

let successors t breadcrumb =
  List.map
    (successor_hashes t (Breadcrumb.state_hash breadcrumb))
    ~f:(find_exn t)

let rec successors_rec t breadcrumb =
  List.bind (successors t breadcrumb) ~f:(fun succ ->
      succ :: successors_rec t succ )

let path_map t breadcrumb ~f =
  let rec find_path b =
    let elem = f b in
    let parent_hash = Breadcrumb.parent_hash b in
    if State_hash.equal (Breadcrumb.state_hash b) t.root then []
    else if State_hash.equal parent_hash t.root then [elem]
    else elem :: find_path (find_exn t parent_hash)
  in
  List.rev (find_path breadcrumb)

let best_tip_path t = path_map t (best_tip t) ~f:Fn.id

(* TODO: create a unit test for hash_path *)
let hash_path t breadcrumb = path_map t breadcrumb ~f:Breadcrumb.state_hash

let iter t ~f = Hashtbl.iter t.table ~f:(fun n -> f n.breadcrumb)

let root t = find_exn t t.root

let shallow_copy_root_snarked_ledger {root_ledger; _} =
  Ledger.of_database root_ledger

let best_tip_path_length_exn {table; root; best_tip; _} =
  let open Option.Let_syntax in
  let result =
    let%bind best_tip_node = Hashtbl.find table best_tip in
    let%map root_node = Hashtbl.find table root in
    best_tip_node.length - root_node.length
  in
  result |> Option.value_exn

let common_ancestor t (bc1 : Breadcrumb.t) (bc2 : Breadcrumb.t) : State_hash.t
    =
  let rec go ancestors1 ancestors2 b1 b2 =
    let sh1 = Breadcrumb.state_hash b1 in
    let sh2 = Breadcrumb.state_hash b2 in
    Hash_set.add ancestors1 sh1 ;
    Hash_set.add ancestors2 sh2 ;
    if Hash_set.mem ancestors1 sh2 then sh2
    else if Hash_set.mem ancestors2 sh1 then sh1
    else
      let parent_unless_root breadcrumb =
        if State_hash.equal (Breadcrumb.state_hash breadcrumb) t.root then
          breadcrumb
        else find_exn t (Breadcrumb.parent_hash breadcrumb)
      in
      go ancestors1 ancestors2 (parent_unless_root b1) (parent_unless_root b2)
  in
  go
    (Hash_set.create (module State_hash) ())
    (Hash_set.create (module State_hash) ())
    bc1 bc2

(* TODO: separate visualizer? *)
(* Visualize the structure of the transition frontier or a particular node
 * within the frontier (for debugging purposes). *)
module Visualizor = struct
  let fold t ~f = Hashtbl.fold t.table ~f:(fun ~key:_ ~data -> f data)

  include Visualization.Make_ocamlgraph (Node)

  let to_graph t =
    fold t ~init:empty ~f:(fun (node : Node.t) graph ->
        let graph_with_node = add_vertex graph node in
        List.fold node.successor_hashes ~init:graph_with_node
          ~f:(fun acc_graph successor_state_hash ->
            match State_hash.Table.find t.table successor_state_hash with
            | Some child_node ->
                add_edge acc_graph node child_node
            | None ->
                Logger.debug t.logger ~module_:__MODULE__ ~location:__LOC__
                  ~metadata:
                    [ ("state_hash", State_hash.to_yojson successor_state_hash)
                    ; ("error", `String "missing from frontier") ]
                  "Could not visualize state $state_hash: $error" ;
                acc_graph ) )
end

let visualize ~filename (t : t) =
  Out_channel.with_file filename ~f:(fun output_channel ->
      let graph = Visualizor.to_graph t in
      Visualizor.output_graph output_channel graph )

let visualize_to_string t =
  let graph = Visualizor.to_graph t in
  let buf = Buffer.create 0 in
  let formatter = Format.formatter_of_buffer buf in
  Visualizor.fprint_graph formatter graph ;
  Format.pp_print_flush formatter () ;
  Buffer.contents buf

(* given an heir, calculate the diff that will transition the root to that heir *)
let calculate_root_transition_diff t heir =
  let open Root_data.Minimal.Stable.V1 in
  let root = root t in
  let heir_hash = Breadcrumb.state_hash heir in
  let heir_staged_ledger = Breadcrumb.staged_ledger heir in
  let heir_siblings =
    List.filter (successors t root) ~f:(fun breadcrumb ->
        not (State_hash.equal heir_hash (Breadcrumb.state_hash breadcrumb)) )
  in
  let garbage_breadcrumbs =
    List.bind heir_siblings ~f:(fun sibling ->
        sibling :: successors_rec t sibling )
  in
  let garbage_hashes = List.map garbage_breadcrumbs ~f:Breadcrumb.state_hash in
  let new_root_data =
    { hash= heir_hash
    ; scan_state= Staged_ledger.scan_state heir_staged_ledger
    ; pending_coinbase=
        Staged_ledger.pending_coinbase_collection heir_staged_ledger }
  in
  Diff.Full.E.E
    (Root_transitioned {new_root= new_root_data; garbage= garbage_hashes})

(* calculates the diffs which need to be applied in order to add a breadcrumb to the frontier *)
let calculate_diffs t breadcrumb =
  let open Diff in
  O1trace.measure "calculate_diffs" (fun () ->
      let breadcrumb_hash = Breadcrumb.state_hash breadcrumb in
      let parent_node =
        Hashtbl.find_exn t.table (Breadcrumb.parent_hash breadcrumb)
      in
      let root_node = Hashtbl.find_exn t.table t.root in
      let current_best_tip = best_tip t in
      let diffs = [Full.E.E (New_node (Full breadcrumb))] in
      (* check if new breadcrumb extends frontier to longer than k *)
      let diffs =
        if parent_node.length + 1 - root_node.length > t.max_length then
          let heir = find_exn t (List.hd_exn (hash_path t breadcrumb)) in
          calculate_root_transition_diff t heir :: diffs
        else diffs
      in
      (* check if new breadcrumb will be best tip *)
      let diffs =
        if
          Consensus.Hooks.select
            ~existing:(Breadcrumb.consensus_state current_best_tip)
            ~candidate:(Breadcrumb.consensus_state breadcrumb)
            ~logger:
              (Logger.extend t.logger
                 [ ( "selection_context"
                   , `String "comparing new breadcrumb to best tip" ) ])
          = `Take
        then Full.E.E (Best_tip_changed breadcrumb_hash) :: diffs
        else diffs
      in
      (* reverse diffs so that they are applied in the correct order *)
      List.rev diffs )

(* TODO: refactor metrics tracking outside of apply_diff (could maybe even be an extension?) *)
let apply_diff (type mutant) t (diff : (Diff.full, mutant) Diff.t) :
    mutant * State_hash.t option =
  match diff with
  | New_node (Full breadcrumb) ->
      let breadcrumb_hash = Breadcrumb.state_hash breadcrumb in
      let parent_hash = Breadcrumb.parent_hash breadcrumb in
      let parent_node = Hashtbl.find_exn t.table parent_hash in
      Hashtbl.add_exn t.table ~key:breadcrumb_hash
        ~data:{breadcrumb; successor_hashes= []; length= parent_node.length + 1} ;
      Hashtbl.set t.table ~key:parent_hash
        ~data:
          { parent_node with
            successor_hashes= breadcrumb_hash :: parent_node.successor_hashes
          } ;
      Coda_metrics.(Gauge.inc_one Transition_frontier.active_breadcrumbs) ;
      Coda_metrics.(Counter.inc_one Transition_frontier.total_breadcrumbs) ;
      ((), None)
  | Best_tip_changed new_best_tip ->
      let old_best_tip = t.best_tip in
      t.best_tip <- new_best_tip ;
      (old_best_tip, None)
  | Root_transitioned {new_root= {hash= new_root_hash; _}; garbage} ->
      (* The transition frontier at this point in time has the following mask topology:
       *
       *   (`s` represents a snarked ledger, `m` represents a mask)
       * 
       *     garbage
       *     [m...]
       *       ^
       *       |          successors
       *       m0 -> m1 -> [m...]
       *       ^
       *       |
       *       s
       *
       * In this diagram, the old root's mask (`m0`) is parented off of the root snarked
       * ledger database, and the new root's mask (`m1`) is parented off of the `m0`.
       * There is also some garbage parented off of `m0`, and some successors that will
       * be kept in the tree after transition which are parented off of `m1`.
       *
       * In order to move the root, we must form a mask `m1'` with the same merkle root
       * as `m1`, except that it is parented directly off of the root snarked ledger
       * instead of `m0`. Furthermore, the root snarked ledger `s` may update to another
       * merkle root as `s'` if there is a proof emitted in the transition between `m0`
       * and `m1`.
       *
       * To form a mask `m1'` and update the snarked ledger from `s` to `s'` (which is a
       * noop in the case of no ledger proof emitted between `m0` and `m1`), we must perform
       * the following operations on masks in order:
       *
       *     1) unattach and destroy all the garbage (to avoid unecessary trickling of
       *        invalidations from `m0` during the next step)
       *     2) commit `m1` into `m0`, making `m0` into `m1'` (same merkle root as `m1`), and
       *        making `m1` into an identity mask (an empty mask on top of `m1'`).
       *     3) safely reparent all the successors of `m1` onto `m1'`
       *     4) unattach and destroy `m1`
       *     5) create a new temporary mask `mt` with `s` as it's parent
       *     6) apply any transactions to `mt` that appear in the transition between `s` and `s'`
       *     7) commit `mt` into `s`, turning `s` into `s'`
       *     8) unattach and destroy `mt`
       *)
      let old_root_node = Hashtbl.find_exn t.table t.root in
      let new_root_node = Hashtbl.find_exn t.table new_root_hash in
      Ledger.Maskable.Debug.visualize ~filename:"pre_masks.dot" ;
      let new_root_mask =
        let m0 = Breadcrumb.mask old_root_node.breadcrumb in
        let m1 = Breadcrumb.mask new_root_node.breadcrumb in
        let m1_hash_pre_commit = Ledger.merkle_root m1 in
        List.iter garbage ~f:(fun garbage_hash ->
            let breadcrumb = Option.value_exn (find t garbage_hash) in
            let mask = Breadcrumb.mask breadcrumb in
            (* this should get garbage collected and should not require additional destruction *)
            ignore
              (Ledger.Maskable.unregister_mask_exn
                 (Ledger.Mask.Attached.get_parent mask)
                 mask) ;
            Hashtbl.remove t.table garbage_hash ) ;
        Hashtbl.remove t.table t.root ;
        Ledger.commit m1 ;
        [%test_result: Ledger_hash.t]
          ~message:
            "Merkle root of new root's staged ledger mask is the same after \
             committing"
          ~expect:m1_hash_pre_commit (Ledger.merkle_root m1) ;
        [%test_result: Ledger_hash.t]
          ~message:
            "Merkle root of old root's staged ledger mask is the same as the \
             new root's staged ledger mask after committing"
          ~expect:m1_hash_pre_commit (Ledger.merkle_root m0) ;
        (* reparent all the successors of m1 onto m0 *)
        Ledger.remove_and_reparent_exn m1 m1 ;
        (*
        ignore
          (Ledger.Maskable.unregister_mask_exn
             (Ledger.Any_ledger.cast (module Ledger.Mask.Attached) m0)
             m1) ;
        *)
        if Breadcrumb.just_emitted_a_proof new_root_node.breadcrumb then (
          let s =
            Ledger.(
              Any_ledger.cast (module Ledger) (of_database t.root_ledger))
          in
          let mt = Ledger.Maskable.register_mask s (Ledger.Mask.create ()) in
          Non_empty_list.iter
            (Option.value_exn
               (Staged_ledger.proof_txns
                  (Breadcrumb.staged_ledger new_root_node.breadcrumb)))
            ~f:(fun txn ->
              ignore (Or_error.ok_exn (Ledger.apply_transaction mt txn)) ) ;
          Ledger.commit mt ;
          ignore (Ledger.Maskable.unregister_mask_exn s mt) ) ;
        m0
      in
      Ledger.Maskable.Debug.visualize ~filename:"post_masks.dot" ;
      let new_root_breadcrumb =
        Breadcrumb.create
          (Breadcrumb.validated_transition new_root_node.breadcrumb)
          (Staged_ledger.replace_ledger_exn
             (Breadcrumb.staged_ledger new_root_node.breadcrumb)
             new_root_mask)
      in
      let new_root_node =
        {new_root_node with breadcrumb= new_root_breadcrumb}
      in
      Hashtbl.set t.table ~key:new_root_hash ~data:new_root_node ;
      t.root <- new_root_hash ;
      Coda_metrics.(
        let num_breadcrumbs_removed = Int.to_float (1 + List.length garbage) in
        let num_finalized_staged_txns =
          Int.to_float
            (List.length (Breadcrumb.user_commands new_root_breadcrumb))
        in
        (* TODO: this metric collection super inefficient right now *)
        let root_snarked_ledger_accounts = Ledger.Db.to_list t.root_ledger in
        let num_root_snarked_ledger_accounts =
          Int.to_float (List.length root_snarked_ledger_accounts)
        in
        let root_snarked_ledger_total_currency =
          Int.to_float
            (List.fold_left root_snarked_ledger_accounts ~init:0
               ~f:(fun sum account ->
                 sum + Currency.Balance.to_int account.balance ))
        in
        Gauge.dec Transition_frontier.active_breadcrumbs
          num_breadcrumbs_removed ;
        Gauge.set Transition_frontier.recently_finalized_staged_txns
          num_finalized_staged_txns ;
        Counter.inc Transition_frontier.finalized_staged_txns
          num_finalized_staged_txns ;
        Gauge.set Transition_frontier.root_snarked_ledger_accounts
          num_root_snarked_ledger_accounts ;
        Gauge.set Transition_frontier.root_snarked_ledger_total_currency
          root_snarked_ledger_total_currency ;
        Counter.inc_one Transition_frontier.root_transitions) ;
      (Breadcrumb.state_hash old_root_node.breadcrumb, Some new_root_hash)
  | New_node (Lite _) ->
      failwith "impossible"

let apply_diffs t diffs =
  let open Root_identifier.Stable.Latest in
  let local_state_was_synced_at_start =
    Consensus.Hooks.required_local_state_sync
      ~consensus_state:(Breadcrumb.consensus_state (best_tip t))
      ~local_state:t.consensus_local_state
    |> Option.is_none
  in
  let new_root =
    List.fold diffs ~init:None ~f:(fun prev_root (Diff.Full.E.E diff) ->
        let mutant, new_root = apply_diff t diff in
        t.hash <- Frontier_hash.merge_diff t.hash (Diff.to_lite diff) mutant ;
        match new_root with
        | None ->
            prev_root
        | Some state_hash ->
            Some {state_hash; frontier_hash= t.hash} )
  in
  Debug_assert.debug_assert (fun () ->
      match
        Consensus.Hooks.required_local_state_sync
          ~consensus_state:
            (Breadcrumb.consensus_state
               (Hashtbl.find_exn t.table t.best_tip).breadcrumb)
          ~local_state:t.consensus_local_state
      with
      | Some jobs ->
          (* But if there wasn't sync work to do when we started, then there shouldn't be now. *)
          if local_state_was_synced_at_start then (
            Logger.fatal t.logger
              "after lock transition, the best tip consensus state is out of \
               sync with the local state -- bug in either \
               required_local_state_sync or frontier_root_transition."
              ~module_:__MODULE__ ~location:__LOC__
              ~metadata:
                [ ( "sync_jobs"
                  , `List
                      ( Non_empty_list.to_list jobs
                      |> List.map ~f:Consensus.Hooks.local_state_sync_to_yojson
                      ) )
                ; ( "local_state"
                  , Consensus.Data.Local_state.to_yojson
                      t.consensus_local_state )
                ; ("tf_viz", `String (visualize_to_string t)) ] ;
            assert false )
      | None ->
          () ) ;
  `New_root new_root
