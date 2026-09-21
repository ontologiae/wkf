(* A graph read from JSON, checked, drawn, priced and walked twice.
   Run it with: dune exec example/demo.exe *)

(* ---- two handlers, which is all the host really owes the engine ---- *)

(* Looks at the context and names the node to go to. A routing node is not a
   nature of its own: it is a handler whose output carries "next". Here it also
   posts the price, which fixes it for the whole traversal. *)
module Triage = struct
  let name = "triage"

  type config = { long_form : string; short_form : string; threshold : int }

  let config_of_json = function
    | `Assoc fields ->
        let string key =
          match List.assoc_opt key fields with
          | Some (`String s) -> s
          | _ -> failwith (Printf.sprintf "field %S is required and must be a string" key)
        in
        let int key =
          match List.assoc_opt key fields with
          | Some (`Int i) -> i
          | _ -> failwith (Printf.sprintf "field %S is required and must be an integer" key)
        in
        { long_form = string "long_form"; short_form = string "short_form"; threshold = int "threshold" }
    | _ -> failwith "an object was expected"

  let read_config = config_of_json

  let run ~config ~context =
    let size =
      match context with
      | `Assoc fields -> (
          match List.assoc_opt "ask" fields with Some (`String s) -> String.length s | _ -> 0)
      | _ -> 0
    in
    let long = size >= config.threshold in
    Lwt.return
      (Ok
         (`Assoc
           [
             ("next", `String (if long then config.long_form else config.short_form));
             ("price", `Int (if long then 30 else 10));
             (* free fields: the engine keeps them and never looks at them *)
             ("asked_characters", `Int size);
           ]))
end

(* Stands in for the expensive work -- a model call, a computation, anything.
   The engine has no notion of what it does, which is why changing what it
   calls is a change in the host and nowhere else. *)
module Work = struct
  let name = "work"

  type config = { label : string; fails : bool }

  let read_config = function
    | `Assoc fields ->
        {
          label =
            (match List.assoc_opt "label" fields with
            | Some (`String s) -> s
            | _ -> failwith "field \"label\" is required");
          fails =
            (match List.assoc_opt "fails" fields with Some (`Bool b) -> b | _ -> false);
        }
    | _ -> failwith "an object was expected"

  let run ~config ~context:_ =
    if config.fails then Lwt.return (Error (config.label ^ " is unavailable"))
    else Lwt.return (Ok (`Assoc [ ("wrote", `String config.label) ]))
end

(* ---- the graph, as a host would have read it from its database ---- *)

let graph_json =
  {|
{ "name": "one_turn",
  "node_budget": 20,
  "nodes": [
    { "name": "triage", "handler": "triage", "start": true, "max_cost": 1,
      "config": { "long_form": "study", "short_form": "note", "threshold": 40 } },

    { "name": "study", "handler": "work", "max_cost": 25,
      "config": { "label": "the long answer" } },

    { "name": "note", "handler": "work", "max_cost": 8,
      "config": { "label": "the short answer" } },

    { "name": "polish", "handler": "work", "max_cost": 4,
      "on_failure": "continue",
      "config": { "label": "the polish", "fails": true } },

    { "name": "done", "handler": "work", "terminal": true, "max_cost": 0,
      "config": { "label": "handing it over" } }
  ],
  "edges": [
    { "from": "study",  "to": "polish" },
    { "from": "note",   "to": "polish" },
    { "from": "polish", "to": "done" }
  ] }
|}

let log event =
  Printf.printf "    %-7s %s\n%!"
    (match Wkf.Event.level event with
    | `Info -> "info"
    | `Warning -> "warn"
    | `Error -> "error")
    (Wkf.Event.to_string event)

let () =
  Wkf.Registry.register (module Triage);
  Wkf.Registry.register (module Work);

  let graph =
    match Wkf.Graph.of_json_string graph_json with
    | Ok g -> g
    | Error message -> failwith ("the graph was refused: " ^ message)
  in
  let loaded, warnings =
    match Wkf.Loaded.of_graph graph with
    | Ok (loaded, warnings) -> (loaded, warnings)
    | Error errors ->
        List.iter (fun e -> prerr_endline (Wkf.Loaded.string_of_error e)) errors;
        exit 1
  in
  List.iter (fun w -> print_endline ("warning: " ^ Wkf.Loaded.string_of_warning w)) warnings;

  print_endline "the most expensive path from each node:";
  List.iter (fun (n, c) -> Printf.printf "  %-8s %d\n" n c) (Wkf.Cost.table loaded);

  (* The announced price is what the entry node posts at its dearest: 30. Does
     the dearest path fit in it? *)
  print_endline ("price check: " ^ Wkf.Cost.string_of_verdict (Wkf.Cost.check_price loaded ~price:30));

  Wkf.Dot.to_file "one_turn.dot" graph;
  print_endline "wrote one_turn.dot (dot -Tsvg one_turn.dot -o one_turn.svg)";

  List.iter
    (fun ask ->
      Printf.printf "\n--- a %d-character question ---\n" (String.length ask);
      let outcome =
        Lwt_main.run
          (Wkf.Engine.run ~on_event:log loaded ~context:(`Assoc [ ("ask", `String ask) ]))
      in
      print_endline ("  => " ^ Wkf.Engine.string_of_outcome outcome);
      match outcome with
      | Wkf.Engine.Completed { trail; _ } ->
          print_endline ("  trail: " ^ Yojson.Safe.to_string (Wkf.Trail.to_json trail))
      | Wkf.Engine.Interrupted _ -> ())
    [ "how are you?"; "would you walk me through what this does, at some length, please?" ]
