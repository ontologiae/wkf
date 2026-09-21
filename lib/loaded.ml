type node = {
  definition : Definition.node;
  run : Registry.runner;
  edge : string option;
}

type t = {
  graph : Definition.t;
  start : string;
  nodes : (string, node) Hashtbl.t;
  dag : Dag.t;
}

type error =
  | No_start_node
  | Several_start_nodes of string list
  | Duplicate_node of string
  | Unknown_handler of { node : string; handler : string }
  | Bad_config of { node : string; handler : string; message : string }
  | Unknown_edge_endpoint of { from_ : string; to_ : string; missing : string }
  | Several_edges_from of string
  | Unknown_failure_target of { node : string; target : string }
  | Divert_without_target of string
  | Non_positive_node_budget of int
  | Cycle of string list

type warning =
  | Unreachable_node of string
  | Terminal_with_edge of string
  | No_way_out of string

let string_of_error = function
  | No_start_node -> "no node is marked as the start of the graph"
  | Several_start_nodes ns ->
      Printf.sprintf "several nodes are marked as the start: %s" (String.concat ", " ns)
  | Duplicate_node n -> Printf.sprintf "two nodes are named %S" n
  | Unknown_handler { node; handler } ->
      Printf.sprintf "node %S names handler %S, which no handler in the registry answers to" node
        handler
  | Bad_config { node; handler; message } ->
      Printf.sprintf "node %S: handler %S refused its configuration: %s" node handler message
  | Unknown_edge_endpoint { from_; to_; missing } ->
      Printf.sprintf "edge %S -> %S: there is no node named %S" from_ to_ missing
  | Several_edges_from n ->
      Printf.sprintf "node %S has more than one outgoing edge; a node has at most one" n
  | Unknown_failure_target { node; target } ->
      Printf.sprintf "node %S diverts to %S on failure, and there is no node named %S" node target
        target
  | Divert_without_target n ->
      Printf.sprintf "node %S is set to divert on failure but names no failure_target" n
  | Non_positive_node_budget b ->
      Printf.sprintf "node_budget is %d; a traversal that may visit no node is not a traversal" b
  | Cycle ns -> Printf.sprintf "these nodes form a cycle: %s" (String.concat " -> " ns)

let string_of_warning = function
  | Unreachable_node n ->
      Printf.sprintf
        "nothing points at node %S: no edge and no fallback branch leads to it, and it is not the \
         start -- which is a forgotten edge far more often than it is a node a handler routes to"
        n
  | Terminal_with_edge n ->
      Printf.sprintf "node %S is terminal and has an outgoing edge, which will never be followed" n
  | No_way_out n ->
      Printf.sprintf
        "node %S is not terminal and has no outgoing edge: unless its handler names a successor, a \
         traversal ends there as interrupted"
        n

(* Duplicates, and the outgoing edges gathered per node. Both are needed before
   anything else: the rest of the checks look nodes and edges up by name. *)
let index_nodes (g : Definition.t) =
  let table = Hashtbl.create 16 in
  let errors =
    List.filter_map
      (fun (n : Definition.node) ->
        if Hashtbl.mem table n.name then Some (Duplicate_node n.name)
        else (
          Hashtbl.replace table n.name n;
          None))
      g.nodes
  in
  (table, errors)

let index_edges (g : Definition.t) known =
  let table = Hashtbl.create 16 in
  let errors =
    List.concat_map
      (fun (e : Definition.edge) ->
        let missing =
          List.filter_map
            (fun v ->
              if Hashtbl.mem known v then None
              else Some (Unknown_edge_endpoint { from_ = e.from_; to_ = e.to_; missing = v }))
            [ e.from_; e.to_ ]
        in
        if missing <> [] then missing
        else if Hashtbl.mem table e.from_ then [ Several_edges_from e.from_ ]
        else (
          Hashtbl.replace table e.from_ e.to_;
          []))
      g.edges
  in
  (table, errors)

let check_start (g : Definition.t) =
  match Definition.start_nodes g with
  | [ n ] -> (Some n.name, [])
  | [] -> (None, [ No_start_node ])
  | several -> (None, [ Several_start_nodes (List.map (fun (n : Definition.node) -> n.name) several) ])

let check_failure_policy known (n : Definition.node) =
  match (n.on_failure, n.failure_target) with
  | `Divert, None -> [ Divert_without_target n.name ]
  | `Divert, Some target when not (Hashtbl.mem known target) ->
      [ Unknown_failure_target { node = n.name; target } ]
  | _ -> []

let of_graph ?(registry = Registry.default) (g : Definition.t) =
  let known, duplicate_errors = index_nodes g in
  let edges, edge_errors = index_edges g known in
  let start, start_errors = check_start g in
  let budget_errors =
    if g.node_budget <= 0 then [ Non_positive_node_budget g.node_budget ] else []
  in
  let policy_errors = List.concat_map (check_failure_policy known) g.nodes in
  (* Resolving the handler and reading the configuration happen here, once, and
     never again: that is the whole point of § "the validation happens when the
     graph is loaded, not during a traversal". *)
  let prepared = Hashtbl.create 16 in
  let handler_errors =
    List.filter_map
      (fun (n : Definition.node) ->
        match Registry.prepare ~registry n.handler n.config with
        | Ok run ->
            Hashtbl.replace prepared n.name
              { definition = n; run; edge = Hashtbl.find_opt edges n.name };
            None
        | Error message ->
            if Registry.mem ~registry n.handler then
              Some (Bad_config { node = n.name; handler = n.handler; message })
            else Some (Unknown_handler { node = n.name; handler = n.handler }))
      g.nodes
  in
  let structural = duplicate_errors @ edge_errors @ start_errors @ budget_errors @ policy_errors in
  match (structural, start) with
  | [], Some start ->
      (* The graph holds together; only now do cycles and reachability mean
         anything. *)
      let dag = Dag.of_definition g in
      let cycle_errors = List.map (fun c -> Cycle c) (Dag.cycles dag) in
      let errors = cycle_errors @ handler_errors in
      if errors <> [] then Error errors
      else
        (* "Nothing points at it" rather than "the start cannot reach it": on a
           graph whose entry node routes -- the ordinary shape -- the start
           reaches nothing through declared edges, and a reachability warning
           would name every node in the graph and mean nothing. A node with no
           incoming edge is the real symptom, and in a DAG every piece that
           hangs loose has at least one. *)
        let points_at name =
          List.exists (fun (e : Definition.edge) -> String.equal e.to_ name) g.edges
          || List.exists
               (fun (n : Definition.node) ->
                 n.on_failure = `Divert && n.failure_target = Some name)
               g.nodes
        in
        let warnings =
          List.filter_map
            (fun (n : Definition.node) ->
              if String.equal n.name start || points_at n.name then None
              else Some (Unreachable_node n.name))
            g.nodes
          @ List.filter_map
              (fun (n : Definition.node) ->
                match (n.terminal, Hashtbl.find_opt edges n.name) with
                | true, Some _ -> Some (Terminal_with_edge n.name)
                | false, None -> Some (No_way_out n.name)
                | _ -> None)
              g.nodes
        in
        Ok ({ graph = g; start; nodes = prepared; dag }, warnings)
  | _ -> Error (structural @ handler_errors)

let graph t = t.graph
let start t = t.start
let find t name = Hashtbl.find_opt t.nodes name
let node_names t = Definition.node_names t.graph
let successors t name = Dag.successors t.dag name
