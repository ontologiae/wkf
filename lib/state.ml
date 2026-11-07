type status = State_t.status

type t = State_t.state = {
  graph : string;
  status : status;
  node : string option;
  trail : Trail.t;
  price : int option;
  visited : int;
  context : Yojson.Safe.t;
  reason : string option;
}

let of_json_string s =
  match State_j.state_of_string s with
  | state -> Ok state
  | exception Atdgen_runtime.Oj_run.Error msg -> Error msg
  | exception Yojson.Json_error msg -> Error msg
  | exception Failure msg -> Error msg

let to_json_string ?(pretty = false) t =
  let s = State_j.string_of_state t in
  if pretty then Yojson.Safe.prettify s else s

let string_of_status = function
  | `Running -> "running"
  | `Ready -> "ready"
  | `Completed -> "completed"
  | `Interrupted -> "interrupted"
  | `Suspended -> "suspended"

let is_resumable t = match t.status with `Running | `Ready | `Suspended -> true | _ -> false

type mismatch =
  | Other_graph of { state : string; graph : string }
  | Unknown_node of string
  | Nothing_to_resume of status
  | No_node

let string_of_mismatch = function
  | Other_graph { state; graph } ->
      Printf.sprintf "this state belongs to graph %S and was handed to graph %S" state graph
  | Unknown_node n ->
      Printf.sprintf "the state stopped at node %S, which this graph does not have -- the graph \
                      has changed under the traversal"
        n
  | Nothing_to_resume s ->
      Printf.sprintf "this traversal is already %s; picking it up again would run its nodes a \
                      second time"
        (string_of_status s)
  | No_node -> "this state names no node, so there is nowhere to resume from"

let check loaded t =
  let graph = (Loaded.graph loaded).name in
  if not (String.equal t.graph graph) then Error (Other_graph { state = t.graph; graph })
  else if not (is_resumable t) then Error (Nothing_to_resume t.status)
  else
    match t.node with
    | None -> Error No_node
    | Some n -> if Option.is_none (Loaded.find loaded n) then Error (Unknown_node n) else Ok n
