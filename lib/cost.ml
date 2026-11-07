(* Dynamic programming over the reverse topological order: a node's cost is its
   own plus the most expensive of its successors'. Ten lines, and they exist
   nowhere ready-made because the longest weighted path is only easy on a DAG.
   The graph is one by the time we get here -- Loaded.of_graph refused it
   otherwise. *)
let table_of t =
  let dag = Dag.of_definition (Loaded.graph t) in
  let cost = Hashtbl.create 16 in
  let cost_of v = Option.value (Hashtbl.find_opt cost v) ~default:0 in
  List.iter
    (fun v ->
      let own =
        match Loaded.find t v with Some n -> n.definition.Definition.max_cost | None -> 0
      in
      let worst_successor =
        List.fold_left (fun acc s -> max acc (cost_of s)) 0 (Dag.successors dag v)
      in
      Hashtbl.replace cost v (own + worst_successor))
    (Dag.reverse_topological dag);
  cost

(* The same fold, with every node weighing one: the most nodes a traversal can
   still visit from a node, that node included. *)
let steps_table t =
  let dag = Dag.of_definition (Loaded.graph t) in
  let steps = Hashtbl.create 16 in
  let steps_of v = Option.value (Hashtbl.find_opt steps v) ~default:0 in
  List.iter
    (fun v ->
      let worst = List.fold_left (fun acc s -> max acc (steps_of s)) 0 (Dag.successors dag v) in
      Hashtbl.replace steps v (1 + worst))
    (Dag.reverse_topological dag);
  steps

let steps_from t name =
  match Loaded.find t name with None -> None | Some _ -> Hashtbl.find_opt (steps_table t) name

let of_node t name =
  match Loaded.find t name with None -> None | Some _ -> Hashtbl.find_opt (table_of t) name

let from_start t = Option.value (of_node t (Loaded.start t)) ~default:0

let table t =
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) (table_of t) []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* A node with no declared edge, no declared route and no terminal flag has to
   be routed by its handler: nothing written down says where it goes. A node
   that declares its routes is not open -- the engine holds it to them, so the
   most expensive path through them is a real bound. Any node may in fact route
   -- a handler can name a successor whether or not an edge exists -- but this
   is the case the graph itself makes unavoidable, and it is the one worth
   naming. *)
let open_nodes t =
  let g = Loaded.graph t in
  let reachable name =
    (* an unreachable node cannot make a traversal's bound worse *)
    String.equal name (Loaded.start t)
    || List.exists (fun (e : Definition.edge) -> String.equal e.to_ name) g.edges
    || List.exists
         (fun (n : Definition.node) -> n.failure_target = Some name)
         g.nodes
    || List.exists (fun (r : Definition.route) -> r.to_node = Some name) g.routes
  in
  List.filter_map
    (fun (n : Definition.node) ->
      if
        (not n.terminal)
        && Definition.successor g n.name = None
        && Definition.routes_from g n.name = []
        && reachable n.name
      then
        Some n.name
      else None)
    g.nodes

type verdict =
  | Within of { cost : int; price : int }
  | Over of { cost : int; price : int }
  | Unbounded of { cost : int; price : int; routing : string list }

let check_price t ~price =
  let cost = from_start t in
  match open_nodes t with
  | [] -> if cost > price then Over { cost; price } else Within { cost; price }
  | routing -> Unbounded { cost; price; routing }

let string_of_verdict = function
  | Within { cost; price } ->
      Printf.sprintf "most expensive path costs %d, announced price is %d" cost price
  | Over { cost; price } ->
      Printf.sprintf
        "most expensive path costs %d, which is more than the announced price of %d: at least one \
         traversal is sold at a loss"
        cost price
  | Unbounded { cost; price; routing } ->
      let named = String.concat ", " (List.map (fun n -> Printf.sprintf "%S" n) routing) in
      Printf.sprintf
        "the declared graph costs at least %d against an announced price of %d, and no more can be \
         said: %s at run time, so where it goes -- and what it costs -- is written down nowhere"
        cost price
        (match routing with
        | [ _ ] -> Printf.sprintf "node %s routes" named
        | _ -> Printf.sprintf "nodes %s route" named)
