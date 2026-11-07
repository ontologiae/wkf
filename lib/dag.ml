(* The graph-theory side of things, delegated to ocamlgraph.

   Internal: nothing here is re-exported by [Wkf]. The rule is not to rewrite
   what a library already does, and ocamlgraph does three things we need --
   cycle detection, strongly connected components (which is what lets a refusal
   NAME the nodes of a cycle rather than return a boolean), and topological
   order. What is left to us is the dynamic programming for the most expensive
   path, which exists nowhere ready-made because it is only easy on a DAG. *)

module G = Graph.Persistent.Digraph.Concrete (String)
module Scc = Graph.Components.Make (G)
module Topo = Graph.Topological.Make (G)

type t = G.t

(* Divert edges are part of the graph, and that matters twice: a fallback
   branch that loops back to an earlier node IS a cycle, and a fallback branch
   is on some traversal's path, so it counts towards the most expensive one.
   Declared routes are here for the same two reasons: a route back to an
   earlier node is a cycle the budget would otherwise have to catch at run
   time, and a routed-to node is on a path. What is NOT here is routing by
   [next] from a node that declares no route: a handler can name any node, and
   no static check can see what was never written down. A route without [to]
   (the node may end the traversal) adds no edge. *)
let of_definition (g : Definition.t) =
  let with_vertices =
    List.fold_left (fun acc (n : Definition.node) -> G.add_vertex acc n.name) G.empty g.nodes
  in
  let with_edges =
    List.fold_left
      (fun acc (e : Definition.edge) -> G.add_edge acc e.from_ e.to_)
      with_vertices g.edges
  in
  let with_fallbacks =
    List.fold_left
      (fun acc (n : Definition.node) ->
        match (n.on_failure, n.failure_target) with
        | `Divert, Some target -> G.add_edge acc n.name target
        | _ -> acc)
      with_edges g.nodes
  in
  List.fold_left
    (fun acc (r : Definition.route) ->
      match r.to_node with Some target -> G.add_edge acc r.from_node target | None -> acc)
    with_fallbacks g.routes

let successors t v = if G.mem_vertex t v then G.succ t v else []

(* A strongly connected component of more than one vertex IS a cycle, and it
   hands over its own member list. A single vertex is one only if it loops on
   itself. *)
let cycles t =
  Scc.scc_list t
  |> List.filter (function [] -> false | [ v ] -> G.mem_edge t v v | _ -> true)
  |> List.map (List.sort String.compare)

(* Reverse topological order: every vertex comes after its successors, which is
   the order a "cost of the most expensive path from here" fold needs. Only
   meaningful on a DAG, so callers run the cycle check first. *)
let reverse_topological t = Topo.fold (fun v acc -> v :: acc) t []
