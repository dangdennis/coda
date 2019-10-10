open Async
open Core
open Coda_base
open Gadt_lib
open Signature_lib
module Gossip_net = Coda_networking.Gossip_net

type peer_network =
  { peer: Network_peer.Peer.t
  ; frontier: Transition_frontier.t
  ; network: Coda_networking.t }

type nonrec 'num_peers t =
  { fake_gossip_network: Gossip_net.Fake.network
  ; peer_networks: (peer_network, 'num_peers) Vect.t }

module Constants = struct
  let init_ip = Int32.of_int_exn 1

  let init_discovery_port = 1337
end

let setup (type n) ?(logger = Logger.null ())
    ?(trust_system = Trust_system.null ())
    ?(time_controller = Block_time.Controller.basic ~logger)
    ~consensus_local_state (frontiers : (Transition_frontier.t, n) Vect.t) :
    n t =
  let _, peers_with_frontiers =
    Vect.fold_map frontiers
      ~init:(Constants.init_ip, Constants.init_discovery_port)
      ~f:(fun (ip, discovery_port) frontier ->
        (* each peer has a distinct IP address, so we lookup frontiers by IP *)
        let peer =
          Network_peer.Peer.create
            (Unix.Inet_addr.inet4_addr_of_int32 ip)
            ~discovery_port ~communication_port:(discovery_port + 1)
        in
        ((Int32.( + ) Int32.one ip, discovery_port + 2), (peer, frontier)) )
  in
  let peers =
    List.map (Vect.to_list peers_with_frontiers) ~f:(fun (peer, _) -> peer)
  in
  let fake_gossip_network = Gossip_net.Fake.create_network peers in
  let config peer =
    let open Coda_networking.Config in
    { logger
    ; trust_system
    ; time_controller
    ; consensus_local_state
    ; creatable_gossip_net=
        Gossip_net.Any.Creatable
          ( (module Gossip_net.Fake)
          , Gossip_net.Fake.create_instance fake_gossip_network peer )
    ; log_gossip_heard=
        {snark_pool_diff= true; transaction_pool_diff= true; new_state= true}
    }
  in
  let peer_networks =
    Vect.map peers_with_frontiers ~f:(fun (peer, frontier) ->
        let network =
          Thread_safe.block_on_async_exn (fun () ->
              (* TODO: merge implementations with coda_lib *)
              Coda_networking.create (config peer)
                ~get_staged_ledger_aux_and_pending_coinbases_at_hash:
                  (fun query_env ->
                  let input = Envelope.Incoming.data query_env in
                  Deferred.return
                    (let open Option.Let_syntax in
                    let%map scan_state, pending_coinbases =
                      Sync_handler
                      .get_staged_ledger_aux_and_pending_coinbases_at_hash
                        ~frontier input
                    in
                    let expected_merkle_root =
                      Option.value
                        (Option.map
                           (Staged_ledger.Scan_state.target_merkle_root
                              scan_state)
                           ~f:Frozen_ledger_hash.to_ledger_hash)
                        ~default:
                          (Ledger.merkle_root (Lazy.force Genesis_ledger.t))
                    in
                    let staged_ledger_hash =
                      Staged_ledger_hash.of_aux_ledger_and_coinbase_hash
                        (Staged_ledger.Scan_state.hash scan_state)
                        expected_merkle_root pending_coinbases
                    in
                    Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
                      ~metadata:
                        [ ( "staged_ledger_hash"
                          , Staged_ledger_hash.to_yojson staged_ledger_hash )
                        ]
                      "sending scan state and pending coinbase" ;
                    (scan_state, expected_merkle_root, pending_coinbases)) )
                ~answer_sync_ledger_query:(fun _ ->
                  failwith "Answer_sync_ledger_query unimplemented" )
                ~get_ancestry:(fun _ -> failwith "Get_ancestry unimplemented")
                ~get_bootstrappable_best_tip:(fun _ ->
                  failwith "Get_bootstrappable_best_tip unimplemented" )
                ~get_transition_chain_proof:(fun query_env ->
                  Deferred.return
                    (Transition_chain_prover.prove ~frontier
                       (Envelope.Incoming.data query_env)) )
                ~get_transition_chain:(fun query_env ->
                  Deferred.return
                    (Sync_handler.get_transition_chain ~frontier
                       (Envelope.Incoming.data query_env)) ) )
        in
        {peer; frontier; network} )
  in
  {fake_gossip_network; peer_networks}

type peer_config = {initial_frontier_size: int} [@@deriving make]

let gen ~max_frontier_length configs =
  let open Quickcheck.Generator.Let_syntax in
  let consensus_local_state =
    Consensus.Data.Local_state.create Public_key.Compressed.Set.empty
  in
  let%map frontiers =
    Vect.Quickcheck_generator.map configs ~f:(fun config ->
        Transition_frontier.For_tests.gen ~consensus_local_state
          ~max_length:max_frontier_length ~size:config.initial_frontier_size ()
    )
  in
  setup ~consensus_local_state frontiers

(*
let send_transition ~logger ~transition_writer ~peer:{peer; frontier}
    state_hash =
  let transition =
    let validated_transition =
      Transition_frontier.find_exn frontier state_hash
      |> Transition_frontier.Breadcrumb.validated_transition
    in
    validated_transition
    |> External_transition.Validation
       .reset_frontier_dependencies_validation
    |> External_transition.Validation.reset_staged_ledger_diff_validation
  in
  Logger.info logger ~module_:__MODULE__ ~location:__LOC__
    ~metadata:
      [ ("peer", Network_peer.Peer.to_yojson peer)
      ; ("state_hash", State_hash.to_yojson state_hash) ]
    "Peer $peer sending $state_hash" ;
  let enveloped_transition =
    Envelope.Incoming.wrap ~data:transition
      ~sender:(Envelope.Sender.Remote peer.host)
  in
  Pipe_lib.Strict_pipe.Writer.write transition_writer
    (`Transition enveloped_transition, `Time_received Constants.time)

let make_transition_pipe () =
  Pipe_lib.Strict_pipe.create ~name:(__MODULE__ ^ __LOC__)
    (Buffered (`Capacity 30, `Overflow Drop_head))
*)