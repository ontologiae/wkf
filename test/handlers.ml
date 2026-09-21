(* The handlers the tests drive the engine with. They are deliberately dumb:
   what is under test is the engine, not them. *)

(* Returns its own configuration as its output. That makes a node's behaviour
   -- including the reserved fields "next", "price" and "failure" -- something
   the test writes in the graph. *)
module Echo = struct
  let name = "echo"

  type config = Yojson.Safe.t

  let read_config c = c
  let run ~config ~context:_ = Lwt.return (Ok config)
end

(* Fails with the message its configuration names. Also the handler whose
   configuration can be malformed, which is how the loader's refusal gets
   tested. *)
module Boom = struct
  let name = "boom"

  type config = { message : string }

  let read_config = function
    | `Assoc fields -> (
        match List.assoc_opt "message" fields with
        | Some (`String message) -> { message }
        | Some _ -> failwith "field \"message\" must be a string"
        | None -> failwith "field \"message\" is required")
    | _ -> failwith "an object was expected"

  let run ~config ~context:_ = Lwt.return (Error config.message)
end

(* Raises rather than returning [Error]: the engine must treat an exception as
   a failure of the node, not as a failure of the traversal. *)
module Crash = struct
  let name = "crash"

  type config = unit

  let read_config _ = ()
  let run ~config:_ ~context:_ = raise (Failure "the handler blew up")
end

(* Reads the context, which the engine carries and never touches. *)
module Read_context = struct
  let name = "read_context"

  type config = { key : string }

  let read_config = function
    | `Assoc fields -> (
        match List.assoc_opt "key" fields with
        | Some (`String key) -> { key }
        | _ -> failwith "field \"key\" is required")
    | _ -> failwith "an object was expected"

  let run ~config ~context =
    let value =
      match context with
      | `Assoc fields -> Option.value (List.assoc_opt config.key fields) ~default:`Null
      | _ -> `Null
    in
    Lwt.return (Ok (`Assoc [ ("seen", value) ]))
end

let registry =
  let r = Wkf.Registry.create () in
  Wkf.Registry.register ~registry:r (module Echo);
  Wkf.Registry.register ~registry:r (module Boom);
  Wkf.Registry.register ~registry:r (module Crash);
  Wkf.Registry.register ~registry:r (module Read_context);
  r
