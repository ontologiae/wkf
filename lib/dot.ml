module V = struct
  type t = Definition.node

  let compare (a : t) (b : t) = String.compare a.name b.name
  let hash (a : t) = Hashtbl.hash a.Definition.name
  let equal (a : t) (b : t) = String.equal a.name b.name
end

(* The label is what tells a declared edge from a fallback branch: both are
   arrows, but they mean quite different things to whoever reads the drawing. *)
module L = struct
  type t = Declared | Fallback

  let compare = compare
  let default = Declared
end

module G = Graph.Persistent.Digraph.ConcreteLabeled (V) (L)

(* The Graphviz functor takes its graph attributes from a closed signature,
   with no room for a parameter, so the title travels through this ref, set
   just before printing. It makes {!of_graph} the one thing in this library
   that is not reentrant across threads; for a drawing function, that is a
   trade worth making. *)
let graph_name = ref "workflow"

module Printer = Graph.Graphviz.Dot (struct
  include G

  let graph_attributes _ = [ `Rankdir `LeftToRight; `Label !graph_name ]
  let default_vertex_attributes _ = [ `Shape `Box; `Style `Rounded ]
  let vertex_name (n : Definition.node) = "\"" ^ String.escaped n.name ^ "\""

  let vertex_attributes (n : Definition.node) =
    let label =
      Printf.sprintf "%s\\n%s%s" n.name n.handler
        (if n.max_cost = 0 then "" else Printf.sprintf "\\nmax_cost %d" n.max_cost)
    in
    [ `Label label ]
    @ (if n.start then [ `Shape `Doublecircle; `Style `Bold ] else [])
    @ (if n.terminal then [ `Shape `Box3d ] else [])
    @ match n.on_failure with `Continue -> [ `Style `Dashed ] | _ -> []

  let get_subgraph _ = None
  let default_edge_attributes _ = []

  let edge_attributes ((_, l, _) : E.t) =
    match l with
    | L.Declared -> []
    | L.Fallback -> [ `Style `Dashed; `Label "on failure"; `Fontsize 10 ]
end)

let build (g : Definition.t) =
  let node name = Definition.node g name in
  let with_vertices =
    List.fold_left (fun acc (n : Definition.node) -> G.add_vertex acc n) G.empty g.nodes
  in
  let with_edges =
    List.fold_left
      (fun acc (e : Definition.edge) ->
        match (node e.from_, node e.to_) with
        | Some a, Some b -> G.add_edge_e acc (a, L.Declared, b)
        | _ -> acc)
      with_vertices g.edges
  in
  List.fold_left
    (fun acc (n : Definition.node) ->
      match (n.on_failure, n.failure_target) with
      | `Divert, Some target -> (
          match node target with
          | Some b -> G.add_edge_e acc (n, L.Fallback, b)
          | None -> acc)
      | _ -> acc)
    with_edges g.nodes

let of_graph ?name (g : Definition.t) =
  graph_name := (match name with Some n -> n | None -> g.name);
  let buffer = Buffer.create 1024 in
  Printer.fprint_graph (Format.formatter_of_buffer buffer) (build g);
  Buffer.contents buffer

let of_loaded ?name t = of_graph ?name (Loaded.graph t)

let to_file ?name path g =
  let out = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out out)
    (fun () -> output_string out (of_graph ?name g))
