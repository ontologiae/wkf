type step = State_t.step = {
  node : string;
  handler : string;
  output : Yojson.Safe.t;
  failure : string option;
}

type t = step list

let steps t = t
let visited t = List.map (fun s -> s.node) t
let last t = match List.rev t with [] -> None | s :: _ -> Some s

let output t name =
  match List.rev (List.filter (fun s -> String.equal s.node name) t) with
  | [] -> None
  | s :: _ -> Some s.output

(* The generated writer, so that a trail written here and a trail written as
   part of a state are the same bytes. *)
let to_json t = Yojson.Safe.from_string (State_j.string_of_trail t)
