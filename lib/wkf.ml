(** A flat DAG workflow engine whose nodes are registered handlers.

    {1 What it is}

    An execution graph, defined outside the program, whose nodes call
    registered functions and some of which decide where to go next.

    The engine is deliberately small, and most of what it is worth is in what
    it does {e not} do:

    - it is not a statechart. No nested states, no parallel regions, no history
      states, no inter-level transitions. Each of those solves a real problem,
      and each costs an execution semantics one can no longer read and corner
      cases one can no longer test;
    - it has no notion of a language model, of a database, of a price list or
      of a user. A node is a call to a handler, full stop: what tells a node
      that queries a model from a node that computes something is the handler,
      not the engine. Adding a kind of work is registering a handler, not
      changing the engine;
    - it stores nothing. It consumes a graph that has already been read, and
      returns a trail the host commits inside its own transaction.

    {1 The shape of a use}

    {[
      (* once, at startup *)
      Wkf.Registry.register (module My_handler);

      (* when the graph changes, or at startup: everything that can be checked
         before a traversal is checked here *)
      match Wkf.Graph.of_json_string json with
      | Error e -> failwith e
      | Ok graph -> (
          match Wkf.Loaded.of_graph graph with
          | Error errors ->
              List.iter (fun e -> prerr_endline (Wkf.Loaded.string_of_error e)) errors
          | Ok (loaded, warnings) ->
              List.iter (fun w -> prerr_endline (Wkf.Loaded.string_of_warning w)) warnings;
              (* before selling it: does the most expensive path fit in the
                 price the entry node announces? *)
              (match Wkf.Cost.check_price loaded ~price:100 with
               | Wkf.Cost.Over _ as v -> prerr_endline (Wkf.Cost.string_of_verdict v)
               | Wkf.Cost.Within _ -> ());

              (* per traversal: the checkpoint is where the host writes the state
                 down, and it is what makes the traversal resumable *)
              let%lwt outcome =
                Wkf.Engine.run loaded ~context:(`Assoc [ ("ask", `String "...") ])
                  ~on_event:(fun e -> log (Wkf.Event.to_string e))
                  ~checkpoint:(fun state -> Db.save ~id (Wkf.State.to_json_string state))
              in
              ...)
    ]}

    And after the service comes back up, for each traversal its own tables
    still call running:

    {[
      match Wkf.State.of_json_string row with
      | Error e -> log e
      | Ok state -> (
          match%lwt Wkf.Engine.resume loaded state ~checkpoint with
          | Error mismatch -> log (Wkf.State.string_of_mismatch mismatch)
          | Ok outcome -> ...)
    ]}

    {1 What the host must provide}

    The list is short, which is the sign the cut was made in the right place:
    the storage of the graph, the handlers, the context, the billing, the log,
    and the transaction. The engine carries an integer it calls a price and
    knows nothing more about it; it emits events and does not care where they
    go. *)

module Graph = Definition
(** The graph as it is written down, and its JSON format. *)

module Registry = Registry
(** The base names, the code does: a node carries the name of a handler. *)

module Loaded = Loaded
(** The gate between what someone wrote and what runs: all the checks. *)

module Cost = Cost
(** The most expensive path, computed on the DAG before anything runs. *)

module Engine = Engine
(** Running a traversal. *)

module Trail = Trail
(** What a traversal went through, returned whether it completed or not. *)

module State = State
(** The state of a traversal, written down at every node boundary so that a
    service which was cut can pick it up again. *)

module Event = Event
(** What a traversal says while it runs. *)

module Dot = Dot
(** Drawing the graph, so that its shape can be looked at. *)
