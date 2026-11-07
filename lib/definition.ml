(* The graph as it is written down, before anything has checked it.
   Exposed to users as [Wkf.Graph]. *)

include Definition_t

type t = Definition_t.graph

let node (g : t) name = List.find_opt (fun (n : node) -> String.equal n.name name) g.nodes

let node_names (g : t) = List.map (fun (n : node) -> n.name) g.nodes

let start_nodes (g : t) = List.filter (fun (n : node) -> n.start) g.nodes

let routes_from (g : t) name = List.filter (fun (r : route) -> String.equal r.from_node name) g.routes

let successor (g : t) name =
  match List.find_opt (fun (e : edge) -> String.equal e.from_ name) g.edges with
  | Some e -> Some e.to_
  | None -> None

let of_json_string s =
  match Definition_j.graph_of_string s with
  | g -> Ok g
  | exception Atdgen_runtime.Oj_run.Error msg -> Error msg
  | exception Yojson.Json_error msg -> Error msg
  | exception Failure msg -> Error msg

let to_json_string ?(pretty = false) (g : t) =
  let s = Definition_j.string_of_graph g in
  if pretty then Yojson.Safe.prettify s else s

let string_of_on_resume = function `Fail -> "fail" | `Rerun -> "rerun"

let string_of_on_failure = function
  | `Stop -> "stop"
  | `Continue -> "continue"
  | `Divert -> "divert"
