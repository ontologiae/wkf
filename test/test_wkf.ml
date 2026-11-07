let registry = Handlers.registry

(* ------------------------------------------------------------------ *)
(* Building graphs without ceremony.                                    *)

let node ?(handler = "echo") ?(config = `Assoc []) ?(max_cost = 0) ?(on_failure = `Stop)
    ?failure_target ?(on_resume = `Fail) ?(start = false) ?(terminal = false) name : Wkf.Graph.node
    =
  { name; handler; config; max_cost; on_failure; failure_target; on_resume; start; terminal }

(* [routes] pairs a node with where it may go, [None] for "may end here". *)
let graph ?(name = "g") ?(node_budget = 50) ?(routes = []) nodes edges : Wkf.Graph.t =
  {
    name;
    node_budget;
    nodes;
    edges = List.map (fun (from_, to_) -> { Wkf.Graph.from_; to_ }) edges;
    routes = List.map (fun (from_node, to_node) -> { Wkf.Graph.from_node; to_node }) routes;
  }

let load g = Wkf.Loaded.of_graph ~registry g

let load_ok g =
  match load g with
  | Ok (loaded, warnings) -> (loaded, warnings)
  | Error errors ->
      Alcotest.failf "the graph was refused: %s"
        (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let errors_of g =
  match load g with
  | Ok _ -> Alcotest.fail "the graph was accepted, and it should not have been"
  | Error errors -> errors

let run ?on_event ?checkpoint ?(context = `Assoc []) loaded =
  Lwt_main.run (Wkf.Engine.run ?on_event ?checkpoint loaded ~context)

let visited = function
  | Wkf.Engine.Completed { trail; _ } | Wkf.Engine.Interrupted { trail; _ } -> Wkf.Trail.visited trail

let check_visited expected outcome =
  Alcotest.(check (list string)) "visited nodes" expected (visited outcome)

(* ------------------------------------------------------------------ *)
(* The JSON format.                                                     *)

let json_roundtrip () =
  let json =
    {|{ "name": "turn", "node_budget": 7,
        "nodes": [ { "name": "entry", "handler": "echo", "start": true,
                     "config": { "price": 12 }, "max_cost": 3 },
                   { "name": "end", "handler": "echo", "terminal": true } ],
        "edges": [ { "from": "entry", "to": "end" } ] }|}
  in
  match Wkf.Graph.of_json_string json with
  | Error e -> Alcotest.failf "the graph was refused: %s" e
  | Ok g ->
      Alcotest.(check string) "name" "turn" g.name;
      Alcotest.(check int) "node budget" 7 g.node_budget;
      Alcotest.(check int) "nodes" 2 (List.length g.nodes);
      Alcotest.(check (list string)) "node names" [ "entry"; "end" ] (Wkf.Graph.node_names g);
      Alcotest.(check (option string)) "declared edge" (Some "end") (Wkf.Graph.successor g "entry");
      (* the defaults are the safe ones *)
      let entry = Option.get (Wkf.Graph.node g "entry") in
      Alcotest.(check bool) "on_failure defaults to stop" true (entry.on_failure = `Stop);
      Alcotest.(check bool) "not terminal by default" false entry.terminal;
      (* and it survives a round trip *)
      (match Wkf.Graph.of_json_string (Wkf.Graph.to_json_string g) with
      | Ok g' -> Alcotest.(check string) "round trip" g.name g'.name
      | Error e -> Alcotest.failf "the re-read graph was refused: %s" e)

let json_refusal_names_the_field () =
  (* "nodes" is missing, and the refusal has to say so: that is the whole point
     of typing the format rather than reading a jsonb by hand. *)
  match Wkf.Graph.of_json_string {|{ "name": "turn" }|} with
  | Ok _ -> Alcotest.fail "a graph without nodes was accepted"
  | Error message ->
      Alcotest.(check bool)
        (Printf.sprintf "the message names the missing field (%s)" message)
        true
        (let re = Str.regexp_string "nodes" in
         try ignore (Str.search_forward re message 0); true with Not_found -> false)

(* ------------------------------------------------------------------ *)
(* What the loader refuses, and how it says it.                         *)

let refuses_unknown_handler () =
  let g = graph [ node ~handler:"nowhere" ~start:true ~terminal:true "a" ] [] in
  match errors_of g with
  | [ Wkf.Loaded.Unknown_handler { node; handler } ] ->
      Alcotest.(check string) "node" "a" node;
      Alcotest.(check string) "handler" "nowhere" handler
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let refuses_bad_config () =
  (* boom wants a "message"; this node does not give it one. The refusal must
     happen when the graph is posted, not in the middle of a traversal. *)
  let g = graph [ node ~handler:"boom" ~start:true ~terminal:true "a" ] [] in
  match errors_of g with
  | [ Wkf.Loaded.Bad_config { node; handler; message } ] ->
      Alcotest.(check string) "node" "a" node;
      Alcotest.(check string) "handler" "boom" handler;
      Alcotest.(check bool) "the message names the field" true
        (String.length message > 0 && String.contains message 'm')
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let names_the_nodes_of_the_cycle () =
  let g =
    graph
      [ node ~start:true "a"; node "b"; node "c"; node ~terminal:true "out" ]
      [ ("a", "b"); ("b", "c"); ("c", "b") ]
  in
  match errors_of g with
  | [ Wkf.Loaded.Cycle nodes ] ->
      (* "this graph has a cycle" helps nobody: the nodes are the point. *)
      Alcotest.(check (list string)) "the cycle is named" [ "b"; "c" ] nodes
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let a_fallback_branch_can_close_a_cycle () =
  (* The divert edge is part of the graph, and a fallback that goes back is as
     much a loop as a declared edge that does. *)
  let g =
    graph
      [
        node ~start:true "a";
        node ~on_failure:`Divert ~failure_target:"a" "b";
        node ~terminal:true "out";
      ]
      [ ("a", "b"); ("b", "out") ]
  in
  match errors_of g with
  | [ Wkf.Loaded.Cycle nodes ] -> Alcotest.(check (list string)) "cycle" [ "a"; "b" ] nodes
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let refuses_a_graph_without_a_start () =
  match errors_of (graph [ node ~terminal:true "a" ] []) with
  | [ Wkf.Loaded.No_start_node ] -> ()
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let refuses_two_starts () =
  match errors_of (graph [ node ~start:true "a"; node ~start:true ~terminal:true "b" ] [ ("a", "b") ]) with
  | [ Wkf.Loaded.Several_start_nodes [ "a"; "b" ] ] -> ()
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let refuses_an_edge_that_leaves_the_graph () =
  match errors_of (graph [ node ~start:true ~terminal:true "a" ] [ ("a", "elsewhere") ]) with
  | [ Wkf.Loaded.Unknown_edge_endpoint { missing; _ } ] ->
      Alcotest.(check string) "missing endpoint" "elsewhere" missing
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let refuses_two_edges_from_one_node () =
  let g =
    graph
      [ node ~start:true "a"; node ~terminal:true "b"; node ~terminal:true "c" ]
      [ ("a", "b"); ("a", "c") ]
  in
  match errors_of g with
  | [ Wkf.Loaded.Several_edges_from "a" ] -> ()
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let refuses_divert_without_target () =
  let g = graph [ node ~start:true ~on_failure:`Divert ~terminal:true "a" ] [] in
  match errors_of g with
  | [ Wkf.Loaded.Divert_without_target "a" ] -> ()
  | errors -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error errors))

let reports_every_error_at_once () =
  (* Fixing a graph one refusal at a time is how an afternoon goes. *)
  let g = graph [ node ~handler:"nowhere" "a"; node ~handler:"nulle_part" "b" ] [] in
  Alcotest.(check int) "three errors, not one" 3 (List.length (errors_of g))

let warns_without_refusing () =
  let g =
    graph
      [
        node ~start:true "a";
        node ~terminal:true "out";
        node "orphan";
        node ~terminal:true "terminal_with_edge";
      ]
      [ ("a", "out"); ("terminal_with_edge", "out") ]
  in
  let _, warnings = load_ok g in
  let has p = List.exists p warnings in
  Alcotest.(check bool) "the orphan is named" true
    (has (function Wkf.Loaded.Unreachable_node "orphan" -> true | _ -> false));
  Alcotest.(check bool) "the useless edge is named" true
    (has (function Wkf.Loaded.Terminal_with_edge "terminal_with_edge" -> true | _ -> false));
  Alcotest.(check bool) "the dead end is named" true
    (has (function Wkf.Loaded.No_way_out "orphan" -> true | _ -> false))

let a_routed_to_node_is_not_called_an_orphan () =
  (* The entry node routes, so through declared edges it reaches nothing. The
     warning must be about what nothing points at -- "study" -- and not about
     everything downstream of it, or it would name the whole graph and mean
     nothing. *)
  let g =
    graph
      [
        node ~start:true ~config:(`Assoc [ ("next", `String "study") ]) "triage";
        node "study";
        node ~terminal:true "out";
      ]
      [ ("study", "out") ]
  in
  let _, warnings = load_ok g in
  Alcotest.(check (list string)) "only the node nothing points at"
    [ "study" ]
    (List.filter_map (function Wkf.Loaded.Unreachable_node n -> Some n | _ -> None) warnings)

(* ------------------------------------------------------------------ *)
(* The most expensive path.                                             *)

let most_expensive_path () =
  (*        b (cost 5) -- d (cost 1)
       a (2)                        \
            c (cost 40) ------------ out (3)   -- but c is a fallback branch *)
  let g =
    graph
      [
        node ~start:true ~max_cost:2 "a";
        node ~max_cost:5 ~on_failure:`Divert ~failure_target:"c" "b";
        node ~max_cost:40 "c";
        node ~max_cost:1 "d";
        node ~max_cost:3 ~terminal:true "out";
      ]
      [ ("a", "b"); ("b", "d"); ("c", "out"); ("d", "out") ]
  in
  let loaded, _ = load_ok g in
  Alcotest.(check (option int)) "from out" (Some 3) (Wkf.Cost.of_node loaded "out");
  Alcotest.(check (option int)) "from d" (Some 4) (Wkf.Cost.of_node loaded "d");
  Alcotest.(check (option int)) "from c" (Some 43) (Wkf.Cost.of_node loaded "c");
  (* b's worst is its fallback, not its declared edge: 5 + 43 *)
  Alcotest.(check (option int)) "from b" (Some 48) (Wkf.Cost.of_node loaded "b");
  Alcotest.(check int) "from the start" 50 (Wkf.Cost.from_start loaded);
  Alcotest.(check (option int)) "an unknown node" None (Wkf.Cost.of_node loaded "nowhere")

let price_check_warns_but_does_not_refuse () =
  let g =
    graph
      [ node ~start:true ~max_cost:10 "a"; node ~max_cost:10 ~terminal:true "out" ]
      [ ("a", "out") ]
  in
  let loaded, _ = load_ok g in
  (match Wkf.Cost.check_price loaded ~price:100 with
  | Wkf.Cost.Within { cost = 20; price = 100 } -> ()
  | v -> Alcotest.failf "unexpected: %s" (Wkf.Cost.string_of_verdict v));
  match Wkf.Cost.check_price loaded ~price:5 with
  | Wkf.Cost.Over { cost = 20; price = 5 } -> ()
  | v -> Alcotest.failf "unexpected: %s" (Wkf.Cost.string_of_verdict v)

let a_routing_node_makes_the_bound_a_lower_bound () =
  (* The shape the whole thing is built around: an entry node that routes, and
     therefore has no declared edge. Nothing written down says where it goes,
     so the most expensive path is not a bound and the verdict says so rather
     than handing back a reassuring 1. *)
  let g =
    graph
      [
        node ~start:true ~max_cost:1 ~config:(`Assoc [ ("next", `String "long") ]) "triage";
        node ~max_cost:90 ~terminal:true "long";
        node ~max_cost:2 ~terminal:true "short";
      ]
      []
  in
  let loaded, _ = load_ok g in
  Alcotest.(check (list string)) "the open node is named" [ "triage" ] (Wkf.Cost.open_nodes loaded);
  match Wkf.Cost.check_price loaded ~price:30 with
  | Wkf.Cost.Unbounded { cost = 1; price = 30; routing = [ "triage" ] } -> ()
  | v -> Alcotest.failf "unexpected: %s" (Wkf.Cost.string_of_verdict v)

(* ------------------------------------------------------------------ *)
(* Traversals.                                                          *)

let follows_the_declared_edges () =
  let g =
    graph
      [ node ~start:true "a"; node "b"; node ~terminal:true "out" ]
      [ ("a", "b"); ("b", "out") ]
  in
  let loaded, _ = load_ok g in
  let outcome = run loaded in
  check_visited [ "a"; "b"; "out" ] outcome;
  match outcome with
  | Wkf.Engine.Completed { price = None; _ } -> ()
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_node_routes_when_its_output_names_the_next_one () =
  let g =
    graph
      [
        node ~start:true ~config:(`Assoc [ ("next", `String "c") ]) "a";
        node "b";
        node ~terminal:true "c";
      ]
      (* the declared edge says b, and the node says c: the node wins *)
      [ ("a", "b"); ("b", "c") ]
  in
  let loaded, _ = load_ok g in
  check_visited [ "a"; "c" ] (run loaded)

let a_null_successor_ends_the_traversal () =
  let g =
    graph
      [ node ~start:true ~config:(`Assoc [ ("next", `Null) ]) "a"; node ~terminal:true "out" ]
      [ ("a", "out") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Completed { trail; _ } ->
      Alcotest.(check (list string)) "stopped at a" [ "a" ] (Wkf.Trail.visited trail)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_handler_naming_a_node_that_does_not_exist () =
  let g =
    graph
      [ node ~start:true ~config:(`Assoc [ ("next", `String "nowhere") ]) "a" ]
      []
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Interrupted { node = "nowhere"; reason; trail } ->
      Alcotest.(check (list string)) "a was visited and is in the trail" [ "a" ]
        (Wkf.Trail.visited trail);
      Alcotest.(check bool) "the reason names it" true (String.length reason > 0)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let the_output_is_kept_whole () =
  let g =
    graph
      [
        node ~start:true
          ~config:(`Assoc [ ("confidence", `Float 0.8); ("read", `List [ `String "x" ]) ])
          ~terminal:true "a";
      ]
      []
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Completed { trail; _ } -> (
      match Wkf.Trail.output trail "a" with
      | Some (`Assoc fields) ->
          Alcotest.(check bool) "the free fields survived" true
            (List.mem_assoc "confidence" fields && List.mem_assoc "read" fields)
      | _ -> Alcotest.fail "the output was not kept")
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let the_context_is_carried_untouched () =
  let g =
    graph
      [ node ~handler:"read_context" ~config:(`Assoc [ ("key", `String "ask") ]) ~start:true
          ~terminal:true "a" ]
      []
  in
  let loaded, _ = load_ok g in
  match run ~context:(`Assoc [ ("ask", `String "the question") ]) loaded with
  | Wkf.Engine.Completed { trail; _ } ->
      Alcotest.(check (option string)) "what the handler saw" (Some "the question")
        (match Wkf.Trail.output trail "a" with
        | Some (`Assoc [ ("seen", `String s) ]) -> Some s
        | _ -> None)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

(* The other channel a node sees, alongside the context: the trail of what
   earlier nodes of this same traversal returned. Unlike the context, it is
   the engine's own, and it is where a decisional node's result reaches
   whatever downstream node needs to use it, not just route past it. *)
let a_node_reads_a_previous_nodes_output_through_the_trail () =
  let g =
    graph
      [
        node ~start:true ~config:(`Assoc [ ("tag", `String "from-a") ]) "a";
        node ~handler:"read_trail" ~config:(`Assoc [ ("node", `String "a") ]) ~terminal:true "b";
      ]
      [ ("a", "b") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Completed { trail; _ } ->
      Alcotest.(check (option string)) "b saw exactly what a returned"
        (Some {|{"tag":"from-a"}|})
        (match Wkf.Trail.output trail "b" with
        | Some (`Assoc [ ("saw", v) ]) -> Some (Yojson.Safe.to_string v)
        | _ -> None)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_node_does_not_see_its_own_unfinished_output () =
  (* a has not returned when its own handler runs, so there is nothing yet to
     find under its name -- the trail passed in is what happened BEFORE this
     node, never including it. *)
  let g =
    graph
      [
        node ~handler:"read_trail" ~config:(`Assoc [ ("node", `String "a") ]) ~start:true
          ~terminal:true "a";
      ]
      []
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Completed { trail; _ } ->
      Alcotest.(check (option string)) "nothing found under its own name yet"
        (Some "null")
        (match Wkf.Trail.output trail "a" with
        | Some (`Assoc [ ("saw", v) ]) -> Some (Yojson.Safe.to_string v)
        | _ -> None)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

(* ------------------------------------------------------------------ *)
(* Failure, node by node.                                               *)

let boom message = node ~handler:"boom" ~config:(`Assoc [ ("message", `String message) ])

let stopping_is_the_default () =
  let g =
    graph [ node ~start:true "a"; boom "no" "b"; node ~terminal:true "out" ]
      [ ("a", "b"); ("b", "out") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Interrupted { node = "b"; reason = "no"; trail } ->
      (* the trail is returned in both cases, and the failed node is in it *)
      Alcotest.(check (list string)) "trail" [ "a"; "b" ] (Wkf.Trail.visited trail);
      Alcotest.(check (option string)) "with its message"
        (Some "no")
        (match Wkf.Trail.last trail with Some s -> s.failure | None -> None)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let continuing_is_something_one_has_to_write () =
  let g =
    graph
      [ node ~start:true "a"; boom ~on_failure:`Continue "never mind" "b"; node ~terminal:true "out" ]
      [ ("a", "b"); ("b", "out") ]
  in
  let loaded, _ = load_ok g in
  check_visited [ "a"; "b"; "out" ] (run loaded)

let a_failure_is_always_logged () =
  let g =
    graph
      [ node ~start:true "a"; boom ~on_failure:`Continue "never mind" "b"; node ~terminal:true "out" ]
      [ ("a", "b"); ("b", "out") ]
  in
  let loaded, _ = load_ok g in
  let events = ref [] in
  ignore (run ~on_event:(fun e -> events := e :: !events) loaded);
  Alcotest.(check bool) "\"carry on\" never means \"say nothing\"" true
    (List.exists
       (function Wkf.Event.Node_failed { node = "b"; _ } -> true | _ -> false)
       !events)

let diverting_takes_the_fallback_branch () =
  let g =
    graph
      [
        node ~start:true "a";
        boom ~on_failure:`Divert ~failure_target:"fallback" "down" "b";
        node "fallback";
        node ~terminal:true "out";
      ]
      [ ("a", "b"); ("b", "out"); ("fallback", "out") ]
  in
  let loaded, _ = load_ok g in
  check_visited [ "a"; "b"; "fallback"; "out" ] (run loaded)

let an_exception_is_a_node_failure () =
  let g =
    graph
      [ node ~start:true "a"; node ~handler:"crash" ~on_failure:`Continue "b"; node ~terminal:true "out" ]
      [ ("a", "b"); ("b", "out") ]
  in
  let loaded, _ = load_ok g in
  check_visited [ "a"; "b"; "out" ] (run loaded)

let a_failure_reported_in_the_output () =
  let g =
    graph
      [ node ~start:true ~config:(`Assoc [ ("failure", `String "not my day") ]) "a"; node ~terminal:true "out" ]
      [ ("a", "out") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Interrupted { node = "a"; reason = "not my day"; _ } -> ()
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_dead_end_interrupts () =
  let g = graph [ node ~start:true "a" ] [] in
  let loaded, warnings = load_ok g in
  Alcotest.(check bool) "and it was warned about at load time" true
    (List.exists (function Wkf.Loaded.No_way_out "a" -> true | _ -> false) warnings);
  match run loaded with
  | Wkf.Engine.Interrupted { node = "a"; _ } -> ()
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

(* ------------------------------------------------------------------ *)
(* The price.                                                           *)

let the_entry_node_fixes_the_price () =
  let g =
    graph
      [ node ~start:true ~config:(`Assoc [ ("price", `Int 40) ]) "a"; node ~terminal:true "out" ]
      [ ("a", "out") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Completed { price = Some 40; _ } -> ()
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_later_node_may_lower_it () =
  let g =
    graph
      [
        node ~start:true ~config:(`Assoc [ ("price", `Int 40) ]) "a";
        node ~config:(`Assoc [ ("price", `Int 10) ]) ~terminal:true "out";
      ]
      [ ("a", "out") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Completed { price = Some 10; _ } -> ()
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_later_node_may_not_raise_it () =
  let g =
    graph
      [
        node ~start:true ~config:(`Assoc [ ("price", `Int 40) ]) "a";
        node ~config:(`Assoc [ ("price", `Int 900) ]) ~terminal:true "out";
      ]
      [ ("a", "out") ]
  in
  let loaded, _ = load_ok g in
  let events = ref [] in
  match run ~on_event:(fun e -> events := e :: !events) loaded with
  | Wkf.Engine.Completed { price = Some 40; _ } ->
      Alcotest.(check bool) "and the engine says it refused" true
        (List.exists
           (function Wkf.Event.Price_raise_refused { asked = 900; kept = 40; _ } -> true | _ -> false)
           !events)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_traversal_that_fails_carries_no_price () =
  let g =
    graph
      [ node ~start:true ~config:(`Assoc [ ("price", `Int 40) ]) "a"; boom "no" "b" ]
      [ ("a", "b") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Interrupted _ -> () (* Interrupted carries no price at all *)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_broken_reserved_field_interrupts () =
  let g =
    graph [ node ~start:true ~config:(`Assoc [ ("price", `String "free") ]) ~terminal:true "a" ] []
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Interrupted { node = "a"; reason; _ } ->
      Alcotest.(check bool) "and says which field" true
        (try ignore (Str.search_forward (Str.regexp_string "price") reason 0); true
         with Not_found -> false)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

(* ------------------------------------------------------------------ *)
(* The node budget: the net under the net.                              *)

let the_node_budget_stops_a_handler_that_loops () =
  (* The graph is acyclic -- a and b point at out. The loop is built at
     runtime, by handlers naming each other, which no static check can see. *)
  let g =
    graph ~node_budget:6
      [
        node ~start:true ~config:(`Assoc [ ("next", `String "b") ]) "a";
        node ~config:(`Assoc [ ("next", `String "a") ]) "b";
        node ~terminal:true "out";
      ]
      [ ("a", "out"); ("b", "out") ]
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Interrupted { trail; _ } ->
      Alcotest.(check int) "it visited exactly the budget" 6 (List.length (Wkf.Trail.visited trail))
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

(* ------------------------------------------------------------------ *)
(* Writing the state down, and picking a cut traversal up again.        *)

(* What a host's table would hold: every state the engine handed over, in
   order. A cut is then simply "stop reading here". *)
let recording () =
  let states = ref [] in
  let checkpoint state =
    states := state :: !states;
    Lwt.return (Ok ())
  in
  (states, checkpoint)

let boundaries states =
  List.rev_map
    (fun (s : Wkf.State.t) ->
      Printf.sprintf "%s %s" (Wkf.State.string_of_status s.status)
        (Option.value s.node ~default:"-"))
    !states

(* The last state a cut would have left behind: a host reads its own table and
   finds the row as it stood. *)
let last_state_at status states =
  List.find (fun (s : Wkf.State.t) -> s.status = status) !states

let straight_graph ?(on_resume = `Fail) ?(on_failure = `Stop) () =
  graph ~name:"walk"
    [
      node ~start:true ~config:(`Assoc [ ("price", `Int 40) ]) "a";
      node ~on_resume ~on_failure ~failure_target:"fallback" "b";
      node "fallback";
      node ~terminal:true "out";
    ]
    [ ("a", "b"); ("b", "out"); ("fallback", "out") ]

let every_node_boundary_is_written_down () =
  let loaded, _ = load_ok (straight_graph ()) in
  let states, checkpoint = recording () in
  let outcome = run ~checkpoint loaded in
  check_visited [ "a"; "b"; "out" ] outcome;
  (* Two writes per node, and the pair is the point: "ready at n" is nothing in
     flight, "running at n" is n interrupted mid-work. *)
  Alcotest.(check (list string)) "boundaries"
    [ "ready a"; "running a"; "ready b"; "running b"; "ready out"; "running out"; "completed out" ]
    (boundaries states);
  (* and the state carries what a resume needs *)
  let final = List.hd !states in
  Alcotest.(check (option int)) "the price travelled" (Some 40) final.price;
  Alcotest.(check int) "so did the visit count" 3 final.visited;
  Alcotest.(check int) "and the trail" 3 (List.length final.trail)

let a_state_survives_a_round_trip_through_json () =
  let loaded, _ = load_ok (straight_graph ()) in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint ~context:(`Assoc [ ("ask", `String "x") ]) loaded);
  let before = List.hd !states in
  match Wkf.State.of_json_string (Wkf.State.to_json_string before) with
  | Error e -> Alcotest.failf "the state was refused: %s" e
  | Ok after ->
      Alcotest.(check string) "graph" before.graph after.graph;
      Alcotest.(check (option string)) "node" before.node after.node;
      Alcotest.(check (option int)) "price" before.price after.price;
      Alcotest.(check int) "visited" before.visited after.visited;
      Alcotest.(check (list string)) "trail"
        (Wkf.Trail.visited before.trail)
        (Wkf.Trail.visited after.trail);
      Alcotest.(check string) "and the context came back too"
        (Yojson.Safe.to_string before.context)
        (Yojson.Safe.to_string after.context)

let resume ?checkpoint ?context loaded state =
  match Lwt_main.run (Wkf.Engine.resume ?checkpoint ?context loaded state) with
  | Ok outcome -> outcome
  | Error mismatch -> Alcotest.failf "refused: %s" (Wkf.State.string_of_mismatch mismatch)

let a_node_in_flight_is_deemed_to_have_failed () =
  let loaded, _ = load_ok (straight_graph ()) in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  (* the service was cut while b was working *)
  let cut = List.find (fun (s : Wkf.State.t) -> s.node = Some "b" && s.status = `Running) !states in
  match resume loaded cut with
  | Wkf.Engine.Interrupted { node = "b"; reason; trail } ->
      Alcotest.(check bool) "the reason says what happened" true
        (try ignore (Str.search_forward (Str.regexp_string "in flight") reason 0); true
         with Not_found -> false);
      (* what was already done is still there, and b is not done twice *)
      Alcotest.(check (list string)) "trail" [ "a"; "b" ] (Wkf.Trail.visited trail)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_node_in_flight_follows_its_own_failure_policy () =
  let loaded, _ = load_ok (straight_graph ~on_failure:`Divert ()) in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  let cut = List.find (fun (s : Wkf.State.t) -> s.node = Some "b" && s.status = `Running) !states in
  check_visited [ "a"; "b"; "fallback"; "out" ] (resume loaded cut)

let a_rerun_node_still_sees_the_trail_from_before_the_cut () =
  (* The trail a node receives comes from state.trail on a resume, not from
     anything the walk accumulated since restarting -- this is what proves the
     two paths (run, resume) feed the same channel. *)
  let g =
    graph ~name:"walk"
      [
        node ~start:true ~config:(`Assoc [ ("tag", `String "from-a") ]) "a";
        node ~handler:"read_trail" ~on_resume:`Rerun ~config:(`Assoc [ ("node", `String "a") ])
          ~terminal:true "b";
      ]
      [ ("a", "b") ]
  in
  let loaded, _ = load_ok g in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  let cut = List.find (fun (s : Wkf.State.t) -> s.node = Some "b" && s.status = `Running) !states in
  match resume loaded cut with
  | Wkf.Engine.Completed { trail; _ } ->
      Alcotest.(check (option string)) "b, rerun after the cut, still sees a's output"
        (Some {|{"tag":"from-a"}|})
        (match Wkf.Trail.output trail "b" with
        | Some (`Assoc [ ("saw", v) ]) -> Some (Yojson.Safe.to_string v)
        | _ -> None)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let rerun_is_something_one_has_to_write () =
  let loaded, _ = load_ok (straight_graph ~on_resume:`Rerun ()) in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  let cut = List.find (fun (s : Wkf.State.t) -> s.node = Some "b" && s.status = `Running) !states in
  let outcome = resume loaded cut in
  check_visited [ "a"; "b"; "out" ] outcome;
  match outcome with
  | Wkf.Engine.Completed { trail; _ } ->
      (* b is in the trail a second time, and this time it worked *)
      Alcotest.(check (list string)) "b did the work" [ "b" ]
        (List.filter_map
           (fun (s : Wkf.Trail.step) ->
             if String.equal s.node "b" && s.failure = None then Some s.node else None)
           (Wkf.Trail.steps trail))
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_state_between_two_nodes_loses_nothing () =
  let loaded, _ = load_ok (straight_graph ()) in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  let cut = List.find (fun (s : Wkf.State.t) -> s.node = Some "b" && s.status = `Ready) !states in
  match resume loaded cut with
  | Wkf.Engine.Completed { trail; price } ->
      Alcotest.(check (list string)) "a is not walked again" [ "a"; "b"; "out" ]
        (Wkf.Trail.visited trail);
      Alcotest.(check (option int)) "and the price the entry node set is still the price" (Some 40)
        price
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let the_budget_means_the_same_on_both_sides_of_a_cut () =
  let g = { (straight_graph ()) with node_budget = 2 } in
  let loaded, _ = load_ok g in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  let cut = List.find (fun (s : Wkf.State.t) -> s.node = Some "b" && s.status = `Ready) !states in
  Alcotest.(check int) "one node was already spent" 1 cut.visited;
  match resume loaded cut with
  | Wkf.Engine.Interrupted { reason; trail; _ } ->
      Alcotest.(check (list string)) "one more node, and that is all" [ "a"; "b" ]
        (Wkf.Trail.visited trail);
      Alcotest.(check bool) "because of the budget" true
        (try ignore (Str.search_forward (Str.regexp_string "budget") reason 0); true
         with Not_found -> false)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_refused_checkpoint_stops_the_traversal () =
  let loaded, _ = load_ok (straight_graph ()) in
  let seen = ref [] in
  let checkpoint (state : Wkf.State.t) =
    if state.node = Some "b" && state.status = `Running then Lwt.return (Error "connection refused")
    else (
      seen := state :: !seen;
      Lwt.return (Ok ()))
  in
  let events = ref [] in
  match run ~checkpoint ~on_event:(fun e -> events := e :: !events) loaded with
  | Wkf.Engine.Interrupted { node = "b"; reason; trail } ->
      Alcotest.(check bool) "the reason says the checkpoint was refused" true
        (try ignore (Str.search_forward (Str.regexp_string "connection refused") reason 0); true
         with Not_found -> false);
      (* b never ran: nothing was spent that nothing could record *)
      Alcotest.(check (list string)) "trail" [ "a" ] (Wkf.Trail.visited trail);
      Alcotest.(check bool) "and it was logged as such" true
        (List.exists
           (function Wkf.Event.Checkpoint_refused { node = "b"; _ } -> true | _ -> false)
           !events)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_completion_that_cannot_be_written_down_is_not_a_completion () =
  let loaded, _ = load_ok (straight_graph ()) in
  let checkpoint (state : Wkf.State.t) =
    if state.status = `Completed then Lwt.return (Error "disk full") else Lwt.return (Ok ())
  in
  match run ~checkpoint loaded with
  | Wkf.Engine.Interrupted { reason; trail; _ } ->
      (* the work is done and the trail says so, but nothing is billed for a
         traversal the host's own books do not know about *)
      Alcotest.(check (list string)) "the trail is whole" [ "a"; "b"; "out" ]
        (Wkf.Trail.visited trail);
      Alcotest.(check bool) "and the reason says why" true
        (try ignore (Str.search_forward (Str.regexp_string "disk full") reason 0); true
         with Not_found -> false)
  | o -> Alcotest.failf "unexpected: %s" (Wkf.Engine.string_of_outcome o)

let a_state_is_refused_when_it_does_not_fit () =
  let loaded, _ = load_ok (straight_graph ()) in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  let a_state = List.hd !states in
  let refusal state =
    match Lwt_main.run (Wkf.Engine.resume loaded state) with
    | Ok o -> Alcotest.failf "it was accepted: %s" (Wkf.Engine.string_of_outcome o)
    | Error m -> m
  in
  (match refusal { a_state with graph = "somewhere else" } with
  | Wkf.State.Other_graph { state = "somewhere else"; graph = "walk" } -> ()
  | m -> Alcotest.failf "unexpected: %s" (Wkf.State.string_of_mismatch m));
  (match refusal { a_state with status = `Ready; node = Some "gone" } with
  | Wkf.State.Unknown_node "gone" -> ()
  | m -> Alcotest.failf "unexpected: %s" (Wkf.State.string_of_mismatch m));
  (* a traversal that is over is over: resuming it would run its nodes twice *)
  match refusal (last_state_at `Completed states) with
  | Wkf.State.Nothing_to_resume `Completed -> ()
  | m -> Alcotest.failf "unexpected: %s" (Wkf.State.string_of_mismatch m)

let a_resumed_traversal_writes_its_own_state_down () =
  let loaded, _ = load_ok (straight_graph ()) in
  let states, checkpoint = recording () in
  ignore (run ~checkpoint loaded);
  let cut = List.find (fun (s : Wkf.State.t) -> s.node = Some "b" && s.status = `Ready) !states in
  let after, checkpoint = recording () in
  ignore (resume ~checkpoint loaded cut);
  (* It restates where it is before doing anything -- which is also how a host
     learns, at no cost, that its checkpoint still works. *)
  Alcotest.(check (list string)) "it picks the writing up where the cut left it"
    [ "ready b"; "running b"; "ready out"; "running out"; "completed out" ]
    (boundaries after)

(* ------------------------------------------------------------------ *)
(* The registry.                                                        *)

let registering_a_name_twice_is_refused () =
  let r = Wkf.Registry.create () in
  Wkf.Registry.register ~registry:r (module Handlers.Echo);
  Alcotest.check_raises "the second one shouts" (Wkf.Registry.Duplicate "echo") (fun () ->
      Wkf.Registry.register ~registry:r (module Handlers.Echo));
  (* replacing is the deliberate act, and it is spelled differently *)
  Wkf.Registry.replace ~registry:r (module Handlers.Echo);
  Alcotest.(check (list string)) "names" [ "echo" ] (Wkf.Registry.names ~registry:r ())

(* ------------------------------------------------------------------ *)
(* The drawing.                                                         *)

let the_graph_can_be_drawn () =
  let g =
    graph ~name:"turn"
      [
        node ~start:true "a";
        node ~on_failure:`Divert ~failure_target:"fallback" "b";
        node "fallback";
        node ~terminal:true "out";
      ]
      [ ("a", "b"); ("b", "out"); ("fallback", "out") ]
  in
  let dot = Wkf.Dot.of_graph g in
  let has s =
    try ignore (Str.search_forward (Str.regexp_string s) dot 0); true with Not_found -> false
  in
  Alcotest.(check bool) "it is a digraph" true (has "digraph");
  Alcotest.(check bool) "the nodes are there" true (has "\"a\"" && has "\"out\"");
  Alcotest.(check bool) "the fallback branch is marked" true (has "on failure")


(* ------------------------------------------------------------------ *)
(* Declared routes.                                                     *)

let routes_are_read_from_json () =
  let json =
    {|{ "name": "turn",
        "nodes": [ { "name": "triage", "handler": "echo", "start": true },
                   { "name": "long", "handler": "echo", "terminal": true } ],
        "routes": [ { "from": "triage", "to": "long" }, { "from": "triage" } ] }|}
  in
  match Wkf.Graph.of_json_string json with
  | Error e -> Alcotest.failf "the graph was refused: %s" e
  | Ok g ->
      Alcotest.(check (list (pair string (option string))))
        "a route with a destination, and one that ends"
        [ ("triage", Some "long"); ("triage", None) ]
        (List.map (fun (r : Wkf.Graph.route) -> (r.from_node, r.to_node)) g.routes)

let refuses_a_route_that_leaves_the_graph () =
  let g =
    graph ~routes:[ ("a", Some "nowhere") ] [ node ~start:true "a"; node ~terminal:true "out" ] [ ("a", "out") ]
  in
  match errors_of g with
  | [ Wkf.Loaded.Unknown_route_endpoint { from_ = "a"; to_ = Some "nowhere"; missing = "nowhere" } ] -> ()
  | es -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error es))

let a_route_back_is_a_cycle () =
  (* Without the declaration this loop is only caught at run time, by the node
     budget. Declared, it is a refusal that names its nodes. *)
  let g =
    graph ~routes:[ ("b", Some "a") ] [ node ~start:true "a"; node "b"; node ~terminal:true "out" ] [ ("a", "b") ]
  in
  match errors_of g with
  | [ Wkf.Loaded.Cycle [ "a"; "b" ] ] -> ()
  | es -> Alcotest.failf "unexpected: %s" (String.concat "; " (List.map Wkf.Loaded.string_of_error es))

let a_routed_to_node_is_no_orphan_once_declared () =
  let g =
    graph
      ~routes:[ ("triage", Some "study"); ("triage", Some "note") ]
      [ node ~start:true "triage"; node ~terminal:true "study"; node ~terminal:true "note" ]
      []
  in
  let _, warnings = load_ok g in
  Alcotest.(check (list string)) "no warning at all" [] (List.map Wkf.Loaded.string_of_warning warnings)

let a_declared_route_is_taken () =
  let g =
    graph
      ~routes:[ ("triage", Some "study"); ("triage", Some "note") ]
      [ node ~start:true ~config:(`Assoc [ ("next", `String "note") ]) "triage";
        node ~terminal:true "study"; node ~terminal:true "note" ]
      []
  in
  let loaded, _ = load_ok g in
  check_visited [ "triage"; "note" ] (run loaded)

let an_undeclared_route_interrupts () =
  let g =
    graph ~routes:[ ("triage", Some "study") ]
      [ node ~start:true ~config:(`Assoc [ ("next", `String "note") ]) "triage";
        node ~terminal:true "study"; node ~terminal:true "note" ]
      []
  in
  let loaded, _ = load_ok g in
  match run loaded with
  | Wkf.Engine.Interrupted { node = "triage"; reason; _ } ->
      Alcotest.(check bool) "the reason names the undeclared successor" true
        (try ignore (Str.search_forward (Str.regexp_string "\"note\"") reason 0); true with Not_found -> false)
  | _ -> Alcotest.fail "a node that named an undeclared successor was followed"

let the_declared_edge_needs_no_route () =
  let g =
    graph ~routes:[ ("a", Some "side") ]
      [ node ~start:true ~config:(`Assoc [ ("next", `String "out") ]) "a";
        node ~terminal:true "side"; node ~terminal:true "out" ]
      [ ("a", "out") ]
  in
  let loaded, _ = load_ok g in
  check_visited [ "a"; "out" ] (run loaded)

let ending_has_to_be_declared_too () =
  let stops routes =
    let g =
      graph ~routes [ node ~start:true ~config:(`Assoc [ ("next", `Null) ]) "a"; node ~terminal:true "out" ] [ ("a", "out") ]
    in
    match run (fst (load_ok g)) with Wkf.Engine.Completed _ -> `Completed | Wkf.Engine.Interrupted _ -> `Interrupted
  in
  Alcotest.(check bool) "declared routes without an end: interrupted" true (stops [ ("a", Some "out") ] = `Interrupted);
  Alcotest.(check bool) "with a route to the end: completed" true (stops [ ("a", None) ] = `Completed);
  Alcotest.(check bool) "no route declared at all: completed, as before" true (stops [] = `Completed)

let declared_routes_close_the_bound () =
  (* The routing entry node of a_routing_node_makes_the_bound_a_lower_bound,
     with its routes written down: the bound is a bound again, and counts the
     most expensive route. *)
  let g =
    graph
      ~routes:[ ("triage", Some "long"); ("triage", Some "short") ]
      [
        node ~start:true ~max_cost:1 "triage";
        node ~max_cost:90 ~terminal:true "long";
        node ~max_cost:2 ~terminal:true "short";
      ]
      []
  in
  let loaded, _ = load_ok g in
  Alcotest.(check (list string)) "no open node" [] (Wkf.Cost.open_nodes loaded);
  match Wkf.Cost.check_price loaded ~price:30 with
  | Wkf.Cost.Over { cost = 91; price = 30 } -> ()
  | v -> Alcotest.failf "unexpected: %s" (Wkf.Cost.string_of_verdict v)

let routes_and_annotations_are_drawn () =
  let g =
    graph ~name:"say \"hi\""
      ~routes:[ ("triage", Some "long"); ("triage", None) ]
      [ node ~start:true "triage"; node ~terminal:true "long"; node ~terminal:true "end" ]
      [ ("triage", "end") ]
  in
  let dot = Wkf.Dot.of_graph ~annotate:(fun n -> if n.name = "long" then [ {|prompt="x"|} ] else []) g in
  let has s = try ignore (Str.search_forward (Str.regexp_string s) dot 0); true with Not_found -> false in
  Alcotest.(check bool) "a route is a dotted arrow" true
    (has {|"triage" -> "long" [fontsize=10, label="route", style="dotted"|});
  Alcotest.(check bool) "the end vertex does not take the name of a node" true (has {|"triage" -> "end'"|});
  Alcotest.(check bool) "an annotation is escaped" true (has {|prompt=\"x\"|});
  Alcotest.(check bool) "the title is escaped" true (has {|say \"hi\"|})

(* ------------------------------------------------------------------ *)

let case name f = Alcotest.test_case name `Quick f

let () =
  Alcotest.run "wkf"
    [
      ( "the JSON format",
        [ case "round trip and defaults" json_roundtrip;
          case "a refusal names the field" json_refusal_names_the_field ] );
      ( "what the loader refuses",
        [
          case "an unknown handler" refuses_unknown_handler;
          case "a configuration the handler rejects" refuses_bad_config;
          case "a cycle, named node by node" names_the_nodes_of_the_cycle;
          case "a cycle closed by a fallback branch" a_fallback_branch_can_close_a_cycle;
          case "no start" refuses_a_graph_without_a_start;
          case "two starts" refuses_two_starts;
          case "an edge that leaves the graph" refuses_an_edge_that_leaves_the_graph;
          case "two edges out of one node" refuses_two_edges_from_one_node;
          case "divert without a destination" refuses_divert_without_target;
          case "all of them at once" reports_every_error_at_once;
          case "and what it only warns about" warns_without_refusing;
          case "a node a handler routes to is not an orphan" a_routed_to_node_is_not_called_an_orphan;
        ] );
      ( "the most expensive path",
        [
          case "computed on the DAG" most_expensive_path;
          case "compared to the price, as a warning" price_check_warns_but_does_not_refuse;
          case "a routing node makes it a lower bound" a_routing_node_makes_the_bound_a_lower_bound;
        ] );
      ( "traversals",
        [
          case "follow the declared edges" follows_the_declared_edges;
          case "a node routes by naming its successor" a_node_routes_when_its_output_names_the_next_one;
          case "a null successor ends it" a_null_successor_ends_the_traversal;
          case "a successor that does not exist" a_handler_naming_a_node_that_does_not_exist;
          case "the free fields are kept" the_output_is_kept_whole;
          case "the context is carried untouched" the_context_is_carried_untouched;
          case "a node budget catches a runtime loop" the_node_budget_stops_a_handler_that_loops;
          case "a node reads a previous one's output through the trail"
            a_node_reads_a_previous_nodes_output_through_the_trail;
          case "a node never sees its own unfinished output"
            a_node_does_not_see_its_own_unfinished_output;
        ] );
      ( "failure, node by node",
        [
          case "stopping is the default" stopping_is_the_default;
          case "carrying on has to be written" continuing_is_something_one_has_to_write;
          case "and is still logged" a_failure_is_always_logged;
          case "diverting takes the fallback branch" diverting_takes_the_fallback_branch;
          case "an exception is a node failure" an_exception_is_a_node_failure;
          case "a failure reported in the output" a_failure_reported_in_the_output;
          case "a dead end interrupts" a_dead_end_interrupts;
        ] );
      ( "the price",
        [
          case "is fixed by the entry node" the_entry_node_fixes_the_price;
          case "a later node may lower it" a_later_node_may_lower_it;
          case "a later node may not raise it" a_later_node_may_not_raise_it;
          case "an interrupted traversal carries none" a_traversal_that_fails_carries_no_price;
          case "a broken reserved field interrupts" a_broken_reserved_field_interrupts;
        ] );
      ( "the state, and picking a cut traversal up again",
        [
          case "every node boundary is written down" every_node_boundary_is_written_down;
          case "a state survives a round trip through JSON" a_state_survives_a_round_trip_through_json;
          case "a node in flight is deemed to have failed" a_node_in_flight_is_deemed_to_have_failed;
          case "and follows its own failure policy" a_node_in_flight_follows_its_own_failure_policy;
          case "a rerun node still sees the trail from before the cut"
            a_rerun_node_still_sees_the_trail_from_before_the_cut;
          case "rerunning it is something one has to write" rerun_is_something_one_has_to_write;
          case "a state between two nodes loses nothing" a_state_between_two_nodes_loses_nothing;
          case "the budget means the same on both sides" the_budget_means_the_same_on_both_sides_of_a_cut;
          case "a refused checkpoint stops the traversal" a_refused_checkpoint_stops_the_traversal;
          case "a completion that cannot be written down" a_completion_that_cannot_be_written_down_is_not_a_completion;
          case "a state that does not fit is refused" a_state_is_refused_when_it_does_not_fit;
          case "a resumed traversal writes its own state" a_resumed_traversal_writes_its_own_state_down;
        ] );
      ("the registry", [ case "a name is registered once" registering_a_name_twice_is_refused ]);
      ( "declared routes",
        [
          case "read from JSON, with and without a destination" routes_are_read_from_json;
          case "a route that leaves the graph is refused" refuses_a_route_that_leaves_the_graph;
          case "a route back is a cycle, named" a_route_back_is_a_cycle;
          case "a routed-to node is no orphan once declared" a_routed_to_node_is_no_orphan_once_declared;
          case "a declared route is taken" a_declared_route_is_taken;
          case "an undeclared one interrupts" an_undeclared_route_interrupts;
          case "the declared edge needs no route" the_declared_edge_needs_no_route;
          case "ending has to be declared too" ending_has_to_be_declared_too;
          case "they close the cost bound" declared_routes_close_the_bound;
        ] );
      ( "drawing",
        [ case "DOT comes out" the_graph_can_be_drawn;
          case "routes, the end and annotations, escaped" routes_and_annotations_are_drawn ] );
    ]
