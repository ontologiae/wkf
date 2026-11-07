(* A vertex is a node of the graph, or the end of the traversal -- the place a
   route without [to] leads. The end is drawn only when some route names it. *)
type vertex = Node of Definition.node | End

module V = struct
  type t = vertex

  let key = function Node n -> Some n.Definition.name | End -> None
  let compare a b = Option.compare String.compare (key a) (key b)
  let hash v = Hashtbl.hash (key v)
  let equal a b = compare a b = 0
end

(* The label is what tells the kinds of arrow apart: all are arrows, and they
   mean quite different things to whoever reads the drawing. A declared edge
   is the default; a fallback branch is taken on failure; a route is where a
   handler may send the traversal, never taken unless it says so. *)
module L = struct
  type t = Declared | Fallback | Route

  let compare = compare
  let default = Declared
end

module G = Graph.Persistent.Digraph.ConcreteLabeled (V) (L)

(* Graph.Graphviz quotes a label as it is, escaping nothing: a double quote in
   a name or an annotation closes the label, and dot then reads the rest as
   something else -- without an error, so the drawing is simply wrong. Every
   piece of text that goes into a label goes through here first, and the line
   breaks are added afterwards. *)
let escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '\\' -> Buffer.add_string b "\\\\"
      | '"' -> Buffer.add_string b "\\\""
      | '\n' -> Buffer.add_string b "\\n"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* The Graphviz functor takes its attributes from closed signatures, with no
   room for a parameter, so the title, the annotations and the id of the end
   vertex travel through these refs, set just before printing. It makes
   {!of_graph} the one thing in this library that is not reentrant across
   threads; for a drawing function, that is a trade worth making. *)
let graph_name = ref "workflow"
let annotations : (Definition.node -> string list) ref = ref (fun _ -> [])
let end_id = ref "end"

module Printer = Graph.Graphviz.Dot (struct
  include G

  let graph_attributes _ = [ `Rankdir `LeftToRight; `Label (escape !graph_name) ]
  let default_vertex_attributes _ = [ `Shape `Box; `Style `Rounded ]

  let vertex_name = function
    | Node n -> "\"" ^ escape n.Definition.name ^ "\""
    | End -> "\"" ^ escape !end_id ^ "\""

  let vertex_attributes = function
    | End -> [ `Shape `Doublecircle; `Label "end"; `Fontsize 9; `Width 0.3; `Height 0.3 ]
    | Node n ->
        let lines =
          [ n.name; n.handler ]
          @ (if n.max_cost = 0 then [] else [ Printf.sprintf "max_cost %d" n.max_cost ])
          @ !annotations n
        in
        [ `Label (String.concat "\\n" (List.map escape lines)) ]
        @ (if n.start then [ `Shape `Doublecircle; `Style `Bold ] else [])
        @ (if n.terminal then [ `Shape `Box3d ] else [])
        @ (match n.on_failure with `Continue -> [ `Style `Dashed ] | _ -> [])

  let get_subgraph _ = None
  let default_edge_attributes _ = []

  let edge_attributes ((_, l, _) : E.t) =
    match l with
    | L.Declared -> []
    | L.Fallback -> [ `Style `Dashed; `Label "on failure"; `Fontsize 10 ]
    | L.Route -> [ `Style `Dotted; `Label "route"; `Fontsize 10 ]
end)

let build (g : Definition.t) =
  let node name = Option.map (fun n -> Node n) (Definition.node g name) in
  let with_vertices = List.fold_left (fun acc n -> G.add_vertex acc (Node n)) G.empty g.nodes in
  let with_edges =
    List.fold_left
      (fun acc (e : Definition.edge) ->
        match (node e.from_, node e.to_) with
        | Some a, Some b -> G.add_edge_e acc (a, L.Declared, b)
        | _ -> acc)
      with_vertices g.edges
  in
  let with_fallbacks =
    List.fold_left
      (fun acc (n : Definition.node) ->
        match (n.on_failure, n.failure_target) with
        | `Divert, Some target -> (
            match node target with Some b -> G.add_edge_e acc (Node n, L.Fallback, b) | None -> acc)
        | _ -> acc)
      with_edges g.nodes
  in
  (* A route to the node its declared edge already leads to adds nothing to
     read: the edge says it. *)
  List.fold_left
    (fun acc (r : Definition.route) ->
      match node r.from_node with
      | None -> acc
      | Some a -> (
          match r.to_node with
          | None -> G.add_edge_e acc (a, L.Route, End)
          | Some t when Definition.successor g r.from_node = Some t -> acc
          | Some t -> ( match node t with Some b -> G.add_edge_e acc (a, L.Route, b) | None -> acc)))
    with_fallbacks g.routes

(* The end vertex needs an id no node has. "end" unless a node is called that,
   then "end'" and so on. *)
let pick_end_id (g : Definition.t) =
  let taken = Definition.node_names g in
  let rec pick s = if List.mem s taken then pick (s ^ "'") else s in
  pick "end"

let of_graph ?name ?(annotate = fun _ -> []) (g : Definition.t) =
  graph_name := (match name with Some n -> n | None -> g.name);
  annotations := annotate;
  end_id := pick_end_id g;
  let buffer = Buffer.create 1024 in
  Printer.fprint_graph (Format.formatter_of_buffer buffer) (build g);
  Buffer.contents buffer

let of_loaded ?name ?annotate t = of_graph ?name ?annotate (Loaded.graph t)

let to_file ?name ?annotate path g =
  let out = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out out)
    (fun () -> output_string out (of_graph ?name ?annotate g))
