open! IStd

module F = Format
module L = Logging
module Domain = LoopusDomain


module Payload = SummaryPayload.Make (struct
  type t = Domain.astate

  let update_payloads astate (payloads : Payloads.t) = {payloads with loopus= Some astate}

  let of_payloads (payloads : Payloads.t) = payloads.loopus
end)

let log : ('a, Format.formatter, unit) format -> 'a = fun fmt -> L.stdout_cond true fmt

module TransferFunctions (ProcCFG : ProcCfg.S) = struct
  module CFG = ProcCFG
  module Domain = Domain

  type nonrec extras = (Typ.t Domain.PvarMap.t * Typ.t Domain.PvarMap.t)

  let pp_session_name node fmt = F.fprintf fmt "loopus %a" CFG.Node.pp_id (CFG.Node.id node)

  (* Take an abstract state and instruction, produce a new abstract state *)
  let exec_instr : Domain.astate -> extras ProcData.t -> CFG.Node.t -> Sil.instr -> Domain.astate =
    fun astate {pdesc; tenv; extras} node instr ->

    let open Domain in

    let locals, formals = extras in

    let is_exit_node = match ProcCFG.Node.kind node with
      | Procdesc.Node.Exit_node -> true
      | _ -> false
    in

    let is_start_node = match ProcCFG.Node.kind node with
      | Procdesc.Node.Start_node -> true
      | _ -> false
    in

    let is_pvar_decl_node = match ProcCFG.Node.kind node with
    | Procdesc.Node.Stmt_node DeclStmt -> true
    | _ -> false
    in

    let rec substitute_pvars exp = match exp with
    | Exp.BinOp (op, lexp, rexp) -> (
      let lexp = substitute_pvars lexp in
      let rexp = substitute_pvars rexp in
      Exp.BinOp (op, lexp, rexp)
    )
    | Exp.UnOp (op, sub_exp, typ) -> (
      let sub_exp = substitute_pvars sub_exp in
      Exp.UnOp (op, sub_exp, typ)
    )
    | Exp.Var ident -> (
      let referenced_pvar = Ident.Map.find ident astate.ident_map in
      Exp.Lvar referenced_pvar
    )
    | _ -> exp
    in

    (* Extracts all formals as pvars from expression *)
    let rec extract_formals pvar_exp acc = match pvar_exp with
    | Exp.BinOp (op, lexp, rexp) -> (
      let acc = extract_formals lexp acc in
      extract_formals rexp acc
    )
    | Exp.UnOp (_, sub_exp, _) -> (
      extract_formals sub_exp acc
    )
    | Exp.Lvar pvar when PvarMap.mem pvar formals -> PvarSet.add pvar acc
    | _ -> acc
    in


    let astate = match instr with
    | Prune (cond, loc, branch, kind) -> (
      log "[PRUNE] (%a) | %a\n" Location.pp loc Exp.pp cond;
      let location_cmp : Location.t -> Location.t -> bool = fun loc_a loc_b ->
        loc_a.line > loc_b.line
      in

      let lts_prune_loc = LTSLocation.PruneLoc (kind, loc) in
      let prune_node = DCP.Node.make lts_prune_loc in

      let astate = match astate.last_node.location with
      | LTSLocation.PruneLoc (kind, prune_loc) 
      when not (is_loop_prune kind) && location_cmp prune_loc loc  -> (
        (* Do not create a backedge from single branch of "if" and 
         * wait for backedge from joined node *)
        astate
      )
      | _ -> (
        let edge_data = DCP.EdgeData.add_invariants astate.edge_data (get_unmodified_pvars astate) in
        let lhs = astate.aggregate_join.lhs in
        let rhs = astate.aggregate_join.rhs in
        let graph_nodes = DCP.NodeSet.add prune_node astate.graph_nodes in

        let is_direct_backedge = LTSLocation.equal lts_prune_loc lhs || LTSLocation.equal lts_prune_loc rhs in
        if is_direct_backedge then (
          (* Discard join node and all edges poiting to it and instead make
            * one direct backedge with variables modified inside the loop *)
          let join_edges =  astate.aggregate_join.edges in
          let src, edge_data, _ = List.find_exn (DCP.EdgeSet.elements join_edges) ~f:(fun edge ->
            let backedge_origin = DCP.E.src edge in
            DCP.Node.equal backedge_origin prune_node
          )
          in
          let edge_data = DCP.EdgeData.set_backedge edge_data in
          let backedge = DCP.E.create src edge_data prune_node in
          let graph_edges = DCP.EdgeSet.add backedge astate.graph_edges in
          let graph_nodes = DCP.NodeSet.remove astate.last_node graph_nodes in
          { astate with graph_edges = graph_edges; graph_nodes = graph_nodes }
        ) else (
          let is_backedge = match lhs, rhs with
          | LTSLocation.PruneLoc (_, lhs), LTSLocation.PruneLoc (_, rhs) -> (
            location_cmp lhs loc || location_cmp rhs loc
          )
          | LTSLocation.PruneLoc (_, lhs), _ -> location_cmp lhs loc
          | _, LTSLocation.PruneLoc (_, rhs) -> location_cmp rhs loc
          | _ -> false
          in
          (* Add all accumulated edges pointing to aggregated join node and
            * new edge pointing from aggregated join node to this prune node *)
          let edge_count = AggregateJoin.edge_count astate.aggregate_join in
          let is_empty_edge = DCP.EdgeData.equal astate.edge_data DCP.EdgeData.empty in
          if not (is_loop_prune kind) && Int.equal edge_count 2 && is_empty_edge then (
            (* LTS simplification, skip simple JOIN node and redirect edges pointing to it *)
            let graph_edges = DCP.EdgeSet.map (fun (src, data, _) ->
              (src, data, prune_node)
            ) astate.aggregate_join.edges
            in
            let graph_nodes = DCP.NodeSet.remove astate.last_node graph_nodes in
            let graph_edges = (DCP.EdgeSet.union astate.graph_edges graph_edges) in
            { astate with graph_edges = graph_edges; graph_nodes = graph_nodes }
          ) else if Int.equal edge_count 1 then (
            (* JOIN node with single incoming edge (useless node).
              * Redirect incoming edge to prune node and delete join node *)
            let graph_edges = DCP.EdgeSet.map (fun (src, edge_data, _) ->
              let edge_data = if is_backedge then DCP.EdgeData.set_backedge edge_data else edge_data in
              (src, edge_data, prune_node)
            ) astate.aggregate_join.edges
            in
            let graph_nodes = DCP.NodeSet.remove astate.last_node graph_nodes in
            let graph_edges = (DCP.EdgeSet.union astate.graph_edges graph_edges) in
            { astate with graph_edges = graph_edges; graph_nodes = graph_nodes }
          ) else (
            let path_end = List.last astate.branchingPath in
            let edge_data = DCP.EdgeData.set_path_end edge_data path_end in
            let edge_data = if is_backedge then DCP.EdgeData.set_backedge edge_data else edge_data in
            let new_lts_edge = DCP.E.create astate.last_node edge_data prune_node in
            let graph_edges = DCP.EdgeSet.add new_lts_edge astate.graph_edges in
            let graph_edges = DCP.EdgeSet.union astate.aggregate_join.edges graph_edges in
            { astate with graph_edges = graph_edges; graph_nodes = graph_nodes }
          )
        )
      )
      in

      let pvar_condition = substitute_pvars cond in
      let prune_condition = match pvar_condition with
      | Exp.BinOp _ -> pvar_condition
      | Exp.UnOp (LNot, exp, _) -> (
        (* Currently handles only "!exp" *)
        match exp with
        | Exp.BinOp (op, lexp, rexp) -> (
          (* Handles "!(lexp BINOP rexp)" *)
          let negate_binop = match op with
          | Binop.Lt -> Binop.Ge
          | Binop.Gt -> Binop.Le
          | Binop.Le -> Binop.Gt
          | Binop.Ge -> Binop.Lt
          | Binop.Eq -> Binop.Ne
          | Binop.Ne -> Binop.Eq
          | _ -> L.(die InternalError)"Unsupported prune condition type!"
          in
          Exp.BinOp (negate_binop, lexp, rexp)
        )
        | Exp.Const const -> Exp.BinOp (Binop.Eq, Exp.Const const, Exp.zero)
        | _ -> L.(die InternalError)"Unsupported prune condition type!"
      )
      | Exp.Const const -> Exp.BinOp (Binop.Ne, Exp.Const const, Exp.zero)
      | _ -> L.(die InternalError)"Unsupported prune condition type!"
      in

      let in_loop = List.exists astate.branchingPath ~f:(fun (kind, branch, _) -> 
        is_loop_prune kind && branch
      )
      in

      let loop_prune = is_loop_prune kind in
      let astate = if loop_prune || in_loop then (
        (* We're tracking formals which are used in
         * conditions of loops headers or on loop paths  *)
        let cond_formals = extract_formals pvar_condition PvarSet.empty in
        if branch then (
          (* Derive norm from prune condition.
           * [x > y] -> [x - y] > 0
           * [x >= y] -> [x - y + 1] > 0 *)
          let normalized_condition = match prune_condition with
          | Exp.BinOp (op, lexp, rexp) -> (
            match op with
            | Binop.Lt -> Exp.BinOp (Binop.Gt, rexp, lexp)
            | Binop.Le -> Exp.BinOp (Binop.Ge, rexp, lexp)
            | _ -> Exp.BinOp (op, lexp, rexp)
          )
          | _ -> prune_condition
          in

          match normalized_condition with
          | Exp.BinOp (op, lexp, rexp) -> (
            let process_gt lhs rhs =
              let lhs_is_zero = Exp.is_zero lhs in
              let rhs_is_zero = Exp.is_zero rhs in
              if lhs_is_zero && rhs_is_zero then Exp.zero
              else if lhs_is_zero then Exp.UnOp (Unop.Neg, rhs, None)
              else if rhs_is_zero then lhs
              else Exp.BinOp (Binop.MinusA, lhs, rhs)
            in

            let process_op op = match op with
              | Binop.Gt -> Some (process_gt lexp rexp)
              | Binop.Ge -> Some (Exp.BinOp (Binop.PlusA, (process_gt lexp rexp), Exp.one))
              | _ -> None
            in
            let astate = match process_op op with
            | Some new_norm -> (
              if not loop_prune then (
                (* Prune on loop path but not loop head. Norm is only potential,
                * must be confirmed by increment/decrement on this loop path *)
                { astate with potential_norms = Exp.Set.add new_norm astate.potential_norms; }
              ) else (
                { astate with initial_norms = Exp.Set.add new_norm astate.initial_norms; }
              )
            ) 
            | None -> astate
            in
            { astate with tracked_formals = PvarSet.union astate.tracked_formals cond_formals }
          )
          | _ -> L.(die InternalError)"Unsupported PRUNE expression!"
        ) else (
          (* Remove formals of condition from false branch *)
          { astate with
            tracked_formals = PvarSet.diff astate.tracked_formals cond_formals;
          }
        )
      ) else (
        astate
      )
      in
      let not_consecutive = DCP.Node.is_join astate.last_node in
      let edge_data = DCP.EdgeData.add_condition DCP.EdgeData.empty prune_condition in
      { astate with
        test = not_consecutive;
        branchingPath = astate.branchingPath @ [(kind, branch, loc)];
        modified_pvars = PvarSet.empty;
        edge_data = edge_data;
        last_node = prune_node;
        aggregate_join = AggregateJoin.initial;
      }
    )
    | Nullify (_, loc) -> (
      log "[NULLIFY] %a\n" Location.pp loc;
      astate
    )
    | Abstract loc -> (
      log "[ABSTRACT] %a\n" Location.pp loc;
      astate
    )
    | Remove_temps (ident_list, loc) -> (
      log "[REMOVE_TEMPS] %a\n" Location.pp loc;

      if is_pvar_decl_node then log "  Decl node\n";
      if is_start_node then (
        let instrs = CFG.instrs node in
        log "  Start node\n";
        let count = Instrs.count instrs in
        log "  Instr count: %d\n" count;
      );

      if is_exit_node then (
        log "  Exit node\n";
        let exit_node = DCP.Node.make LTSLocation.Exit in
        let path_end = List.last astate.branchingPath in
        let edge_data = DCP.EdgeData.set_path_end astate.edge_data path_end in
        let new_lts_edge = DCP.E.create astate.last_node edge_data exit_node in
        let graph_edges = DCP.EdgeSet.add new_lts_edge astate.graph_edges in
        { astate with
          graph_nodes = DCP.NodeSet.add exit_node astate.graph_nodes;
          graph_edges = DCP.EdgeSet.union astate.aggregate_join.edges graph_edges;
        }
      ) else (
        astate
      )
    )
    | Store (Exp.Lvar assigned, _expType, rexp, loc) -> (
      log "[STORE] (%a) | %a = %a | %B\n"
      Location.pp loc Pvar.pp_value assigned Exp.pp rexp is_pvar_decl_node;

      (* Substitute rexp based on previous assignments,
        * eg. [beg = i; end = beg;] becomes [beg = i; end = i] *)
      let pvar_rexp = substitute_pvars rexp in
      let pvar_rexp = match pvar_rexp with
      | Exp.BinOp (Binop.PlusA, Exp.Lvar lexp, Exp.Const (Const.Cint c1)) -> (
        (* [BINOP] PVAR + CONST *)
        match (DCP.EdgeData.get_assignment_rhs astate.edge_data lexp) with
        | Exp.BinOp (Binop.PlusA, lexp, Exp.Const (Const.Cint c2)) -> (
          (* [BINOP] (PVAR + C1) + C2 -> PVAR + (C1 + C2) *)
          let const = Exp.Const (Const.Cint (IntLit.add c1 c2)) in
          Exp.BinOp (Binop.PlusA, lexp, const)
        )
        | _ -> pvar_rexp
      )
      | Exp.Lvar rhs_pvar -> (
        DCP.EdgeData.get_assignment_rhs astate.edge_data rhs_pvar
      )
      | _ -> pvar_rexp
      in
      let is_plus_minus_op op = match op with
      | Binop.PlusA | Binop.MinusA -> true | _ -> false
      in

      let astate = match pvar_rexp with 
      | Exp.BinOp (op, Exp.Lvar pvar, Exp.Const (Const.Cint _)) when Pvar.equal assigned pvar -> (
        let assigned_exp = Exp.Lvar assigned in
        if is_plus_minus_op op && Exp.Set.mem assigned_exp astate.potential_norms then (
          { astate with
            potential_norms = Exp.Set.remove assigned_exp astate.potential_norms;
            initial_norms = Exp.Set.add assigned_exp astate.potential_norms;
          }
        ) else (
          astate
        )
      )
      | _ -> astate
      in

      (* Check if set already contains assignment with specified
        * lhs and replace it with updated formulas if so. Needed
        * when one edge contains multiple assignments to same variable *)
      let edge_data = DCP.EdgeData.add_assignment astate.edge_data assigned pvar_rexp in
      let astate = {astate with edge_data = edge_data} in
      let locals = if is_pvar_decl_node then (
        PvarSet.add assigned astate.locals
      ) else (
        astate.locals
      )
      in
      { astate with
        locals = locals;
        edge_data = edge_data;
        modified_pvars = PvarSet.add assigned astate.modified_pvars;
      }
    )
    | Load (ident, lexp, _typ, loc) -> (
      log "[LOAD] (%a) | %a = %a\n" Location.pp loc Ident.pp ident Exp.pp lexp;
      let ident_map = match lexp with
      | Exp.Lvar pvar -> Ident.Map.add ident pvar astate.ident_map
      | Exp.Var id -> (
        let pvar = Ident.Map.find id astate.ident_map in
        Ident.Map.add ident pvar astate.ident_map
      )
      | _ -> L.(die InternalError)"Unsupported LOAD lhs-expression type!"
      in
      { astate with ident_map = ident_map }
    )
    | Call (_retValue, Const Cfun callee_pname, _actuals, loc, _) -> (
      let _fun_name = Typ.Procname.to_simplified_string callee_pname in
      log "[CALL] (%a)\n" Location.pp loc;
      astate
    )
    | _ -> (
      log "[UNKNOWN INSTRUCTION]\n";
      astate
    )
    in
    astate
 end


module CFG = ProcCfg.NormalOneInstrPerNode
(* module CFG = ProcCfg.Normal *)

module SCC = Graph.Components.Make(Domain.DCP)

module Analyzer = AbstractInterpreter.Make (CFG) (TransferFunctions)
  module Increments = Caml.Set.Make(struct
    type nonrec t = Domain.DCP.E.t * IntLit.t
    [@@deriving compare]
  end)
  
  module Resets = Caml.Set.Make(struct
    type nonrec t = Domain.DCP.E.t * Exp.t * IntLit.t
    [@@deriving compare]
  end)

  type cache = {
    updates: (Increments.t * Resets.t) Exp.Map.t;
    variable_bounds: Domain.Bound.t Exp.Map.t;
    reset_chains: Domain.RG.Chain.Set.t Exp.Map.t;
  }

  let empty_cache = { 
    updates = Exp.Map.empty; 
    variable_bounds = Exp.Map.empty;
    reset_chains = Exp.Map.empty;
  }

  let checker {Callbacks.tenv; proc_desc; summary} : Summary.t =
    let open Domain in

    let beginLoc = Procdesc.get_loc proc_desc in
    let proc_name = Procdesc.get_proc_name proc_desc in
    log "\n\n---------------------------------";
    log "\n- ANALYZING %s" (Typ.Procname.to_simplified_string proc_name);
    log "\n---------------------------------\n";
    log " Begin location: %a\n" Location.pp beginLoc;

    let proc_name = Procdesc.get_proc_name proc_desc in
    let formals_mangled = Procdesc.get_formals proc_desc in
    let formals = List.fold formals_mangled ~init:PvarMap.empty ~f:(fun acc (name, typ) ->
      let formal_pvar = Pvar.mk name proc_name in
      PvarMap.add formal_pvar typ acc
    )
    in
    let locals = Procdesc.get_locals proc_desc in
    let locals = List.fold locals ~init:PvarMap.empty ~f:(fun acc (local : ProcAttributes.var_data) ->
      log "%a\n" Procdesc.pp_local local;
      let pvar = Pvar.mk local.name proc_name in
      PvarMap.add pvar local.typ acc
    )
    in
    let type_map = PvarMap.union (fun key typ1 typ2 ->
      L.(die InternalError)"Type map pvar clash!"
    ) locals formals
    in
    let extras = (locals, formals) in
    let proc_data = ProcData.make proc_desc tenv extras in
    let begin_loc = LTSLocation.Start beginLoc in
    let entry_point = DCP.Node.make begin_loc in
    let initial_state = initial entry_point in
    match Analyzer.compute_post proc_data ~initial:initial_state with
    | Some post -> (
      log "\n---------------------------------";
      log "\n------- [ANALYSIS REPORT] -------";
      log "\n---------------------------------\n";
      log "%a" pp post;

      (* Draw dot graph, use nodes and edges stored in post state *)
      let lts = DCP.create () in
      DCP.NodeSet.iter (fun node ->
        log "%a = %d\n" LTSLocation.pp node.location node.id;
        DCP.add_vertex lts node;
      ) post.graph_nodes;
      DCP.EdgeSet.iter (fun edge ->
        DCP.add_edge_e lts edge;
      ) post.graph_edges;

      let file = Out_channel.create "LTS.dot" in
      LTSDot.output_graph file lts;
      Out_channel.close file;

      log "[INITIAL NORMS]\n";
      Exp.Set.iter (fun norm -> log "  %a\n" Exp.pp norm) post.initial_norms;
      let dcp = DCP.create () in
      DCP.NodeSet.iter (fun node ->
        DCP.add_vertex dcp node;
      ) post.graph_nodes;


      (* Much easier to implement and more readable in imperative style.
        * Derive difference constraints for each edge for each norm and
        * add newly created norms unprocessed_norms set during the process *)
      let unprocessed_norms = ref post.initial_norms in
      let processed_norms = ref Exp.Set.empty in
      while not (Exp.Set.is_empty !unprocessed_norms) do (
        let norm = Exp.Set.min_elt !unprocessed_norms in
        unprocessed_norms := Exp.Set.remove norm !unprocessed_norms;
        processed_norms := Exp.Set.add norm !processed_norms;
        DCP.EdgeSet.iter (fun (_, edge_data, _) ->
          let new_norms = DCP.EdgeData.derive_constraints edge_data norm formals in

          (* Remove already processed norms and add new norms to unprocessed set *)
          let new_norms = Exp.Set.diff new_norms (Exp.Set.inter new_norms !processed_norms) in
          unprocessed_norms := Exp.Set.union new_norms !unprocessed_norms;
        ) post.graph_edges;
      ) done;

      log "[FINAL NORMS]\n";
      Exp.Set.iter (fun norm -> log "  %a\n" Exp.pp norm) !processed_norms;

      (* All DCs and norms are derived, now derive guards.
        * Use Z3 SMT solver to check which norms on which
        * transitions are guaranted to be greater than 0
        * based on conditions that hold on specified transition.
        * For example if transition is guarded by conditions
        * [x >= 0] and [y > x] then we can prove that
        * norm [x + y] > 0 thus it is a guard on this transition *)
      let cfg = [("model", "true"); ("proof", "true")] in
      let ctx = (Z3.mk_context cfg) in
      let solver = (Z3.Solver.mk_solver ctx None) in
      DCP.EdgeSet.iter (fun (src, edge_data, dst) ->
        DCP.EdgeData.derive_guards edge_data !processed_norms solver ctx;
        DCP.add_edge_e dcp (src, edge_data, dst);
      ) post.graph_edges;

      let guarded_nodes = DCP.fold_edges_e (fun (_, edge_data, dst) acc ->
        if Exp.Set.is_empty edge_data.guards then acc else DCP.NodeSet.add dst acc
      ) dcp DCP.NodeSet.empty
      in

      (* Propagate guard to all outgoing edges if all incoming edges
        * are guarded by this guard and the guard itself is not decreased
        * on any of those incoming edges (guard is a norm) *)
      let rec propagate_guards : DCP.NodeSet.t -> unit = fun nodes -> (
        if not (DCP.NodeSet.is_empty nodes) then (
          let rec get_shared_guards : Exp.Set.t -> DCP.edge list -> Exp.Set.t =
          fun guards edges -> match edges with
          | (_, edge_data, _) :: edges -> (
            if edge_data.backedge then (
              get_shared_guards guards edges
            ) else (
              (* Get edge guards that are not decreased on this edge *)
              let guards = DCP.EdgeData.active_guards edge_data in
              Exp.Set.inter guards (get_shared_guards guards edges)
            )
          )
          | [] -> guards
          in

          let node = DCP.NodeSet.min_elt nodes in
          let nodes = DCP.NodeSet.remove node nodes in
          match node.location with
          | LTSLocation.PruneLoc (kind, loc) when is_loop_prune kind -> (
            let incoming_edges = DCP.pred_e dcp node in
            let guards = get_shared_guards Exp.Set.empty incoming_edges in
            let out_edges = DCP.succ_e dcp node in
            let true_branch, out_edges = List.partition_tf out_edges ~f:(fun (_, edge_data, _) -> 
              match edge_data.path_prefix_end with
              | Some (_, branch, _) when branch -> true
              | _ -> false
            )
            in
            let (src, true_branch, dst) = List.hd_exn true_branch in
            true_branch.guards <- Exp.Set.union guards true_branch.guards;
            if not (DCP.Node.equal src dst) then propagate_guards (DCP.NodeSet.add dst nodes);
            let (_, backedge, _) = List.find_exn incoming_edges ~f:(fun (_, edge_data, _) -> edge_data.backedge) in
            let backedge_guards = DCP.EdgeData.active_guards backedge in
            let guards = Exp.Set.inter guards backedge_guards in
            if Exp.Set.is_empty guards then () else (
              let nodes = List.fold out_edges ~init:DCP.NodeSet.empty ~f:(fun acc (_, (edge_data : DCP.EdgeData.t), dst) ->
                edge_data.guards <- Exp.Set.union guards edge_data.guards;
                if edge_data.backedge then acc else DCP.NodeSet.add dst acc
              )
              in
              propagate_guards nodes
            )
          )
          | _ -> (
            let incoming_edges = DCP.pred_e dcp node in

            (* Get guards that are used on all incoming
              * edges and which are not decreased *)
            let guards = get_shared_guards Exp.Set.empty incoming_edges in
            let nodes = if Exp.Set.is_empty guards then (
              nodes
            ) else (
              (* Propagate guards to all outgoing edges and add
                * destination nodes of those edges to the processing queue *)
              let out_edges = DCP.succ_e dcp node in
              List.fold out_edges ~init:nodes ~f:(fun acc (_, (edge_data : DCP.EdgeData.t), dst) ->
                edge_data.guards <- Exp.Set.union guards edge_data.guards;
                if edge_data.backedge then acc else DCP.NodeSet.add dst acc
              )
            )
            in
            propagate_guards nodes
          )
        ) else (
          ()
        )
      )
      in
      propagate_guards guarded_nodes;

      (* Output Guarded DCP over integers *)
      let file = Out_channel.create "DCP_guarded.dot" in
      GuardedDCPDot.output_graph file dcp;
      Out_channel.close file;

      (* Convert DCP with guards to DCP without guards over natural numbers *)
      let to_natural_numbers : DCP.EdgeSet.t -> unit = fun edges -> (
        DCP.EdgeSet.iter (fun (_, edge_data, _) ->
          let constraints = DC.Map.fold (fun lhs (rhs, const) acc ->
            let dc_rhs = if IntLit.isnegative const then (
              (* lhs != rhs hack for now, abstraction algorithm presented in the thesis
               * doesn't add up in the example 'SingleLinkSimple' where they have [i]' <= [n]-1
               * which is indeed right if we want to get valid bound but their abstraction algorithm
               * leads to [i]' <= [n] because there's no guard for n on the transition *)
              let const = if Exp.Set.mem rhs edge_data.guards || not (Exp.equal lhs rhs) then IntLit.minus_one 
              else IntLit.zero in
              rhs, const
            ) else (
              rhs, const
            )
            in
            DC.Map.add lhs dc_rhs acc
          ) edge_data.constraints DC.Map.empty
          in
          edge_data.constraints <- constraints;
        ) edges
      )
      in
      to_natural_numbers post.graph_edges;

      let file = Out_channel.create "DCP.dot" in
      DCPDot.output_graph file dcp;
      Out_channel.close file;

      let reset_graph = RG.create () in
      DCP.EdgeSet.iter (fun (src, edge_data, dst) -> 
        (* Search for resets *)
        DC.Map.iter (fun lhs_norm (rhs_norm, const) -> 
          if not (Exp.equal lhs_norm rhs_norm) then (
            let add_node node = if not (RG.mem_vertex reset_graph node) then (
              RG.add_vertex reset_graph node;
            )
            in
            let lhs_node = RG.Node.make lhs_norm in
            let rhs_node = RG.Node.make rhs_norm in
            add_node lhs_node;
            add_node rhs_node;
            let edge = RG.Edge.make (src, edge_data, dst) const in
            let edge = RG.E.create rhs_node edge lhs_node in
            RG.add_edge_e reset_graph edge;
            ()
          )
        ) edge_data.constraints;
      ) post.graph_edges;

      let file = Out_channel.create "ResetGraph.dot" in
      let () = RG_Dot.output_graph file reset_graph in
      Out_channel.close file;

      (* Suboptimal way to find all SCC edges, the ocamlgraph library for some
       * reason does not have a function that returns edges of SCCs.  *)
      let get_scc_edges dcp =
        let components = SCC.scc_list dcp in
        let scc_edges = List.fold components ~init:DCP.EdgeSet.empty ~f:(fun acc component ->
          (* Iterate over all combinations of SCC nodes and check if there
          * are edges between them in both directions *)
          List.fold component ~init:acc ~f:(fun acc node ->
            List.fold component ~init:acc ~f:(fun acc node2 ->
              let edges = DCP.EdgeSet.of_list (DCP.find_all_edges dcp node node2) in
              DCP.EdgeSet.union acc edges
            )
          )
        )
        in
        (* log "[SCC]\n"; *)
        DCP.EdgeSet.iter (fun (src, _, dst) -> 
          (* log "  %a --- %a\n" GraphNode.pp src GraphNode.pp dst; *) ()
        ) scc_edges;
        scc_edges
      in

      (* Edges that are not part of any SCC can be executed only once,
       * thus their local bound mapping is 1 and consequently their
       * transition bound TB(t) is 1 *)
      let scc_edges = get_scc_edges dcp in
      let non_scc_edges = DCP.EdgeSet.diff post.graph_edges scc_edges in
      DCP.EdgeSet.iter (fun (_, edge_data, _) ->
        edge_data.bound_norm <- Some Exp.one;
      ) non_scc_edges;

      (* For each variable norm construct a E(v) set of edges where it is decreased
       * and assign each edge from this set local bound of v *)
      let norm_edge_sets, processed_edges = Exp.Set.fold (fun norm (sets, processed_edges) ->
        let get_edge_set norm = DCP.EdgeSet.filter (fun (_, edge_data, _) ->
          match DC.Map.get_dc norm edge_data.constraints with
          | Some dc when DC.same_norms dc && DC.is_decreasing dc-> (
            edge_data.bound_norm <- Some norm;
            true
          )
          | _ -> false
        ) scc_edges
        in
        match norm with
        | Exp.Lvar pvar -> (
          if PvarMap.mem pvar formals then sets, processed_edges
          else (
            let bounded_edges = get_edge_set norm in
            let sets = Exp.Map.add norm bounded_edges sets in
            sets, DCP.EdgeSet.union processed_edges bounded_edges
          )
        )
        | Exp.BinOp _ -> (
          (* [TODO] Validate that norm is not purely built over symbolic constants *)
          let bounded_edges = get_edge_set norm in
          let sets = Exp.Map.add norm bounded_edges sets in
          sets, DCP.EdgeSet.union processed_edges bounded_edges
        )
        | Exp.Const _ -> sets, processed_edges
        | _ -> L.(die InternalError)"[Norm edge sets] Invalid norm expression!"
        ) !processed_norms (Exp.Map.empty, DCP.EdgeSet.empty)
      in
      Exp.Map.iter (fun norm edge_set ->
        (* log "E(%a):\n" Exp.pp norm; *)
        DCP.EdgeSet.iter (fun (src, edge_data, dst) ->
          let local_bound = match edge_data.bound_norm with
          | Some bound -> bound
          | None -> L.(die InternalError)""
          in
          ()
          (* log "  %a -- %a -- %a\n" GraphNode.pp src Exp.pp local_bound GraphNode.pp dst *)
        ) edge_set
      ) norm_edge_sets;

      (* Find local bounds for remaining edges that were not processed by
       * the first or second step. Use previously constructed E(v) sets
       * and for each set try to remove edges from the DCP graph. If some
       * unprocessed edges cease to be part of any SCC after the removal,
       * assign variable v as local bound of those edges *)
      let remaining_edges = Exp.Map.fold (fun norm edges remaining_edges ->
        if DCP.EdgeSet.is_empty remaining_edges then (
          remaining_edges
        ) else (
          if not (DCP.EdgeSet.is_empty edges) then (
            (* Remove edges of E(v) set from DCP *)
            DCP.EdgeSet.iter (fun edge -> DCP.remove_edge_e dcp edge) edges;

            (* Calculate SCCs for modified graph *)
            let scc_edges = get_scc_edges dcp in
            let non_scc_edges = DCP.EdgeSet.diff remaining_edges scc_edges in
            DCP.EdgeSet.iter (fun (_, edge_data, _) -> 
              edge_data.bound_norm <- Some norm
            ) non_scc_edges;

            (* Restore DCP *)
            DCP.EdgeSet.iter (fun edge -> DCP.add_edge_e dcp edge) edges;
            DCP.EdgeSet.diff remaining_edges non_scc_edges
          ) else (
            remaining_edges
          )
        )
      ) norm_edge_sets (DCP.EdgeSet.diff scc_edges processed_edges)
      in
      if not (DCP.EdgeSet.is_empty remaining_edges) then (
        L.(die InternalError)"[Local bound mapping] Local bounds could not be determined for all edges"
      );

      log "[Local bounds]\n";
      DCP.EdgeSet.iter (fun (src, edge_data, dst) ->
        let local_bound = match edge_data.bound_norm with
        | Some bound -> bound
        | None -> L.(die InternalError)""
        in
        log "  %a -- %a -- %a\n" DCP.Node.pp src Exp.pp local_bound DCP.Node.pp dst
      ) post.graph_edges;

      log "[Backedges]\n";
      let backedges = DCP.EdgeSet.filter (fun (src, edge_data, dst) ->
        if edge_data.backedge then (
          log "  %a -- %a\n" DCP.Node.pp src DCP.Node.pp dst;
          true
        ) else false
      ) post.graph_edges
      in

      let get_update_map norm edges cache =
        if Exp.Map.mem norm cache.updates then (
          cache
        ) else (
          (* Create missing increments and resets sets for this variable norm *)
          let updates = DCP.EdgeSet.fold (fun edge (increments, resets) ->
            let _, edge_data, _ = edge in
            match DC.Map.get_dc norm edge_data.constraints with
            | Some dc -> (
              (* Variable norm is used on this edge *)
              let _, rhs_norm, const = dc in
              if not (DC.same_norms dc) then (
                (* Must be a reset *)
                let resets = Resets.add (edge, rhs_norm, const) resets in
                increments, resets
              ) else if DC.is_increasing dc then (
                (* Must be a increment *)
                let increments = Increments.add (edge, const) increments in
                (increments, resets)
              ) else (increments, resets)
            )
            | None -> (increments, resets)
          ) edges (Increments.empty, Resets.empty)
          in
          { cache with updates = Exp.Map.add norm updates cache.updates }
        )
      in

      let rec calculate_increment_sum norm cache = 
        (* Calculates increment sum based on increments of variable norm:
         * SUM(TB(t) * const) for all edges where norm is incremented, 0 if nowhere *)
        let cache = get_update_map norm post.graph_edges cache in
        let increments, _ = Exp.Map.find norm cache.updates in
        Increments.fold (fun (dcp_edge, const) (sum, cache) ->
          let edge_bound, cache = transition_bound dcp_edge cache in
          let increment_exp = if Bound.is_zero edge_bound then (
            None
          ) else (
            if IntLit.isone const then (
              Some edge_bound
            ) else (
              let const_exp = Exp.Const (Const.Cint const) in
              if Bound.is_one edge_bound then Some (Bound.Value const_exp)
              else Some (Bound.BinOp (Binop.Mult, edge_bound, Bound.Value const_exp))
            )
          )
          in
          let sum = match sum with
          | Some sum -> (
            match increment_exp with
            | Some exp -> Some (Bound.BinOp (Binop.PlusA, sum, exp))
            | None -> Some sum
          )
          | None -> increment_exp
          in
          sum, cache
        ) increments (None, cache)

      and calculate_reset_sum chains cache = RG.Chain.Set.fold (fun chain (sum, cache) ->
        (* Calculates reset sum based on possible reset chains of reseted norm:
          * SUM( TB(trans(chain)) * max( VB(in(chain)) + value(chain), 0)) for all reset chains,
          * where: trans(chain) = all transitions of a reset chain
          * in(chain) = norm of initial transition of a chain
          * value(chain) = sum of constants on edges along a chain *)

        let norm = RG.Chain.origin chain in
        let chain_value = RG.Chain.value chain in
        let var_bound, cache = variable_bound norm cache in
        let max_exp, cache = if IntLit.isnegative chain_value then (
          (* result can be negative, wrap bound expression in the max function *)
          let const_bound = Bound.Value (Exp.Const (Const.Cint (IntLit.neg chain_value))) in
          let binop_bound = match var_bound with
          | Bound.Max args -> (
            (* max(max(x, 0) - 1, 0) == max(x - 1, 0) *)
            Bound.BinOp (Binop.MinusA, (List.hd_exn args), const_bound)
          )
          | _ -> Bound.BinOp (Binop.MinusA, var_bound, const_bound)
          in
          Bound.Max [binop_bound], cache
        ) else if IntLit.iszero chain_value then (
          var_bound, cache
        ) else (
          (* const > 0 => result must be positive, max function is useless *)
          let const_bound = Bound.Value (Exp.Const (Const.Cint chain_value)) in
          let binop_bound = Bound.BinOp (Binop.PlusA, var_bound, const_bound) in
          binop_bound, cache
        )
        in

        (* Creates a list of arguments for min(args) function. Arguments are
         * transition bounds of each transition of a reset chain. Zero TB stops
         * the fold as we cannot get smaller value. *)
        let fold_aux (args, cache) (dcp_edge : DCP.E.t) =
          let open Base.Continue_or_stop in
          let edge_bound, cache = transition_bound dcp_edge cache in
          if Bound.is_zero edge_bound then Stop ([Bound.Value (Exp.zero)], cache) 
          else (
            match List.hd args with
            | Some arg when Bound.is_one arg -> Continue (args, cache)
            | _ -> (
              if Bound.is_one edge_bound then Continue ([edge_bound], cache) 
              else Continue (args @ [edge_bound], cache)
            )
          )
        in
        let reset_exp, cache = if Bound.is_zero max_exp then (
            None, cache
          ) else (
            let chain_transitions = DCP.EdgeSet.elements (RG.Chain.transitions chain) in
            let args, cache = List.fold_until chain_transitions ~init:([], cache) ~f:fold_aux ~finish:(fun acc -> acc) in
            let edge_bound = if Int.equal (List.length args) 1 then List.hd_exn args else Bound.Min (args) in
            if Bound.is_one edge_bound then Some max_exp, cache
            else Some (Bound.BinOp (Binop.Mult, edge_bound, max_exp)), cache
          )
        in
        let sum = match sum with
        | Some sum -> (
          match reset_exp with
          | Some exp -> Some (Bound.BinOp (Binop.PlusA, sum, exp))
          | None -> Some sum
        )
        | None -> reset_exp
        in
        sum, cache
      ) chains (None, cache)

      and variable_bound norm cache =
        match Exp.Map.find_opt norm cache.variable_bounds with
        | Some bound -> bound, cache
        | None -> (
          let norm_bound = Bound.Value norm in
          let var_bound, cache = match norm with
          | Exp.Lvar pvar -> (
            if PvarMap.mem pvar formals then (
              match PvarMap.find_opt pvar type_map with
              | Some typ -> (match typ.desc with
                | Typ.Tint ikind -> if Typ.ikind_is_unsigned ikind then (
                    (* for unsigned x: max(x, 0) => x *)
                    norm_bound, cache
                  ) else (
                    (* for signed x: max(x, 0) *)
                    Bound.Max [norm_bound], cache
                  )
                | _ -> L.(die InternalError)"[VB] Unexpected Lvar type!"
              )
              | None -> L.(die InternalError)"[VB] Lvar [%a] is not a local variable!" Pvar.pp_value pvar
            ) else (
              let cache = get_update_map norm post.graph_edges cache in
              let _, resets = Exp.Map.find norm cache.updates in
              let increment_sum, cache = calculate_increment_sum norm cache in
              let max_args, cache = Resets.fold (fun (_, norm, const) (args, cache) -> 
                let var_bound, cache = variable_bound norm cache in
                let max_arg = if IntLit.isnegative const then (
                  let const = Bound.Value (Exp.Const (Const.Cint (IntLit.neg const))) in
                  [Bound.BinOp (Binop.MinusA, var_bound, const)]
                ) else if IntLit.iszero const then (
                  if Bound.is_zero var_bound then [] else [var_bound]
                ) else (
                  let const = Bound.Value (Exp.Const (Const.Cint const)) in
                  [Bound.BinOp (Binop.PlusA, var_bound, const)]
                )
                in
                args @ max_arg, cache
              ) resets ([], cache)
              in
              let max = if Int.equal (List.length max_args) 1 then (
                let arg = List.hd_exn max_args in
                match arg with
                | Bound.Value _ -> arg
                | _ -> arg
              ) else (
                Bound.Max max_args
              )
              in
              let var_bound = match increment_sum with
              | Some increments -> Bound.BinOp (Binop.PlusA, increments, max)
              | None -> max
              in
              var_bound, cache
            )
          )
          | Exp.Const Const.Cint const_norm -> (
            if IntLit.isnegative const_norm then Bound.Max [norm_bound], cache
            else norm_bound, cache
          )
          | _ -> L.(die InternalError)"[VB] Unsupported norm expression [%a]!" Exp.pp norm
          in
          let vb_cache = Exp.Map.add norm var_bound cache.variable_bounds in
          let cache = { cache with variable_bounds = vb_cache } in
          var_bound, cache
        )

      and transition_bound (src, (edge_data : DCP.EdgeData.t), dst) cache =
        (* For variable norms: TB(t) = IncrementSum + ResetSum 
         * For constant norms: TB(t) = constant *)
        log "[TB] %a -- %a\n" DCP.Node.pp src DCP.Node.pp dst;
        match edge_data.bound_cache with
        | Some bound_cache -> bound_cache, cache 
        | None -> (
          match edge_data.bound_norm with
          | Some norm -> (
            log "   [Local bound] %a\n" Exp.pp norm;
            let bound, cache = match norm with
            | Exp.Lvar pvar when not (PvarMap.mem pvar formals) -> (

              (* Get reset chains for local bound *)
              let reset_chains, cache = match Exp.Map.find_opt norm cache.reset_chains with
              | Some chains -> chains, cache
              | None -> (
                let chains = RG.get_reset_chains {norm} reset_graph dcp in
                let cache = { cache with reset_chains = Exp.Map.add norm chains cache.reset_chains } in
                chains, cache
              )
              in
              RG.Chain.Set.iter (fun chain ->
                log "   [Reset Chain] %a\n" RG.Chain.pp chain;
              ) reset_chains;

              let chain_norms = RG.Chain.Set.fold (fun chain norms ->
                Exp.Set.union norms (RG.Chain.norms chain)
              ) reset_chains Exp.Set.empty
              in
              let increment_sum, cache = Exp.Set.fold (fun chain_norm (total_sum, cache) -> 
                let sum, cache = calculate_increment_sum chain_norm cache in
                let total_sum = match total_sum, sum with
                | Some total_sum, Some sum -> Some (Bound.BinOp (Binop.PlusA, total_sum, sum))
                | Some sum, None | None, Some sum -> Some sum
                | None, None -> None
                in
                total_sum, cache
              ) chain_norms (None, cache)
              in
              let reset_sum, cache = calculate_reset_sum reset_chains cache in
              
              let edge_bound = match increment_sum, reset_sum with
              | Some increments, Some resets -> Bound.BinOp (Binop.PlusA, increments, resets)
              | Some bound, None | None, Some bound -> bound
              | None, None -> Bound.Value (Exp.zero)
              in
              edge_bound, cache
            )
            | Exp.Const (Const.Cint _) -> (
              (* Non-loop edge, can be executed only once, const is always 1 *)
              Bound.Value norm, cache
            )
            | _ -> L.(die InternalError)"[Bound] Unsupported norm expression [%a]!" Exp.pp norm
            in
            log "[Edge bound (%a)] %a\n" Exp.pp norm Bound.pp bound;
            edge_data.bound_cache <- Some bound;
            bound, cache
          )
          | None -> L.(die InternalError)"[Bound] edge has no bound norm!"
        )
      in

      (* Calculate bound for all backedeges and sum them to get the total bound *)
      let final_bound, _ = DCP.EdgeSet.fold (fun edge (final_bound, cache) ->
        let edge_bound, cache = transition_bound edge cache in
        let final_bound = match final_bound with
        | Some sum -> Bound.BinOp (Binop.PlusA, sum, edge_bound)
        | None -> edge_bound
        in
        Some final_bound, cache
      ) backedges (None, empty_cache)
      in
      log "\n[Final bound]\n";
      (match final_bound with
      | Some bound -> (
        (* let bound_expr = Z3.Expr.simplify (Bound.to_z3_expr bound ctx) None in
        let bound_ast = Z3.Expr.ast_of_expr bound_expr in *)
        log "  %a\n" Bound.pp bound;
      )
      | None -> ());
      log "Description:\n  signed x: max(x, 0) == [x]\n";
      Payload.update_summary post summary
    )
    | None ->
      L.(die InternalError)
      "Analyzer failed to compute post for %a" Typ.Procname.pp
      (Procdesc.get_proc_name proc_data.pdesc)