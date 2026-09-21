type runner = context:Yojson.Safe.t -> (Yojson.Safe.t, string) result Lwt.t

module type HANDLER = sig
  val name : string

  type config

  val read_config : Yojson.Safe.t -> config

  val run :
    config:config -> context:Yojson.Safe.t -> (Yojson.Safe.t, string) result Lwt.t
end

(* A handler is stored with its configuration type already erased: what the
   registry keeps is the function that turns a node's JSON into a runner. It is
   the only shape that lets handlers with different configuration types live in
   the same table. *)
type entry = { name : string; prepare : Yojson.Safe.t -> (runner, string) result }

type t = (string, entry) Hashtbl.t

let create () : t = Hashtbl.create 16
let default = create ()

exception Duplicate of string

let entry_of_module (module H : HANDLER) =
  let prepare config =
    match H.read_config config with
    | config -> Ok (fun ~context -> H.run ~config ~context)
    | exception Failure msg -> Error msg
    | exception Atdgen_runtime.Oj_run.Error msg -> Error msg
    | exception Yojson.Json_error msg -> Error msg
    | exception exn -> Error (Printexc.to_string exn)
  in
  { name = H.name; prepare }

let register ?(registry = default) h =
  let e = entry_of_module h in
  if Hashtbl.mem registry e.name then raise (Duplicate e.name);
  Hashtbl.replace registry e.name e

let replace ?(registry = default) h =
  let e = entry_of_module h in
  Hashtbl.replace registry e.name e

let mem ?(registry = default) name = Hashtbl.mem registry name

let names ?(registry = default) () =
  Hashtbl.fold (fun k _ acc -> k :: acc) registry [] |> List.sort String.compare

let prepare ?(registry = default) name config =
  match Hashtbl.find_opt registry name with
  | None -> Error (Printf.sprintf "no handler named %S in the registry" name)
  | Some e -> e.prepare config

let of_string_reader read json = read (Yojson.Safe.to_string json)
