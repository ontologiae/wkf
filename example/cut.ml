(* A traversal cut in the middle, and picked up again.
   Run it with: dune exec example/cut.exe

   The store here is a ref. In a real host it is a table, and
   schema/wkf.sql has one -- with wkf_save_state() and wkf_traversal_state()
   doing exactly what the two functions below do. *)

let calls : (string, int) Hashtbl.t = Hashtbl.create 8

let count node =
  Hashtbl.replace calls node (1 + Option.value (Hashtbl.find_opt calls node) ~default:0)

(* Expensive work with a visible side effect: how many times it actually ran is
   the whole question a resume has to answer. *)
module Work = struct
  let name = "work"

  type config = { label : string; price : int option }

  let read_config = function
    | `Assoc fields ->
        {
          label =
            (match List.assoc_opt "label" fields with
            | Some (`String s) -> s
            | _ -> failwith "field \"label\" is required");
          price = (match List.assoc_opt "price" fields with Some (`Int p) -> Some p | _ -> None);
        }
    | _ -> failwith "an object was expected"

  let run ~config ~context:_ =
    count config.label;
    Printf.printf "      [%s ran]\n%!" config.label;
    Lwt.return
      (Ok
         (match config.price with
         | Some p -> `Assoc [ ("wrote", `String config.label); ("price", `Int p) ]
         | None -> `Assoc [ ("wrote", `String config.label) ]))
end

let graph_json =
  {|
{ "name": "one_turn", "node_budget": 20,
  "nodes": [
    { "name": "triage", "handler": "work", "start": true, "max_cost": 1,
      "config": { "label": "triage", "price": 40 } },
    { "name": "study",  "handler": "work", "max_cost": 25,
      "config": { "label": "the expensive part" } },
    { "name": "done",   "handler": "work", "terminal": true,
      "config": { "label": "handing it over" } }
  ],
  "edges": [ { "from": "triage", "to": "study" }, { "from": "study", "to": "done" } ] }
|}

(* The host's table: one row, overwritten at every boundary. *)
let row : Wkf.State.t option ref = ref None

let log e = Printf.printf "    %s\n%!" (Wkf.Event.to_string e)

let () =
  Wkf.Registry.register (module Work);
  let graph = Result.get_ok (Wkf.Graph.of_json_string graph_json) in
  let loaded, _ = Result.get_ok (Wkf.Loaded.of_graph graph) in

  (* The machine goes down while "study" is working: the checkpoint is the last
     thing that happens before the work starts, and then nothing more is
     written. *)
  let cut_at_study (state : Wkf.State.t) =
    if state.node = Some "study" && state.status = `Running then begin
      row := Some state;
      print_endline "\n  *** the service goes down here ***\n";
      Lwt.return (Error "the service was cut")
    end
    else begin
      row := Some state;
      Lwt.return (Ok ())
    end
  in
  print_endline "--- first attempt ---";
  let outcome =
    Lwt_main.run
      (Wkf.Engine.run loaded ~on_event:log ~checkpoint:cut_at_study
         ~context:(`Assoc [ ("ask", `String "a question") ]))
  in
  print_endline ("  => " ^ Wkf.Engine.string_of_outcome outcome);

  let saved = Option.get !row in
  print_endline "\n--- what the table holds, and what a service reads at startup ---";
  print_endline ("  " ^ Wkf.State.to_json_string saved);

  print_endline "\n--- the service comes back up ---";
  let keep state =
    row := Some state;
    Lwt.return (Ok ())
  in
  (match Lwt_main.run (Wkf.Engine.resume loaded saved ~on_event:log ~checkpoint:keep) with
  | Error mismatch -> print_endline ("  refused: " ^ Wkf.State.string_of_mismatch mismatch)
  | Ok outcome -> print_endline ("  => " ^ Wkf.Engine.string_of_outcome outcome));

  (* The same cut, against a graph that says that node's work may be done
     again. Nothing else changes -- not the state, not the handler. *)
  print_endline "\n--- the same state, on a graph where that node is declared rerunnable ---";
  let rerunnable : Wkf.Graph.t =
    {
      graph with
      nodes =
        List.map
          (fun (n : Wkf.Graph.node) ->
            if String.equal n.name "study" then { n with on_resume = `Rerun } else n)
          graph.nodes;
    }
  in
  let loaded, _ = Result.get_ok (Wkf.Loaded.of_graph rerunnable) in
  (match Lwt_main.run (Wkf.Engine.resume loaded saved ~on_event:log ~checkpoint:keep) with
  | Error mismatch -> print_endline ("  refused: " ^ Wkf.State.string_of_mismatch mismatch)
  | Ok outcome -> print_endline ("  => " ^ Wkf.Engine.string_of_outcome outcome));

  print_endline "\n--- how many times each node actually ran ---";
  Hashtbl.iter (fun node n -> Printf.printf "  %-20s %d\n" node n) calls;
  print_endline
    "\n  \"triage\" ran once and only once: everything it had done was in the trail, and a\n\
    \  resume does not do it again. \"the expensive part\" was in flight at the cut, and what\n\
    \  became of it was decided by the graph and not by the engine: refused by default --\n\
    \  the engine cannot know whether its work reached the outside world, and paying twice is\n\
    \  what a resume exists to avoid -- and done again only where \"on_resume\": \"rerun\" says\n\
    \  the work is idempotent."
