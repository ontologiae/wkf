type t =
  | Traversal_started of { graph : string; node : string }
  | Node_started of { node : string; handler : string }
  | Node_finished of { node : string; handler : string }
  | Node_failed of {
      node : string;
      handler : string;
      message : string;
      policy : Definition.on_failure;
    }
  | Price_set of { node : string; price : int }
  | Price_lowered of { node : string; before : int; after : int }
  | Price_raise_refused of { node : string; asked : int; kept : int }
  | Terminal_named_next of { node : string; ignored : string }
  | Budget_exhausted of { node : string; budget : int }
  | Traversal_resumed of { graph : string; node : string; in_flight : bool }
  | Node_rerun_after_cut of { node : string }
  | Checkpoint_refused of { node : string; message : string }
  | Traversal_completed of { price : int option; visited : int }
  | Traversal_interrupted of { node : string; reason : string }

let level = function
  | Node_failed _ | Traversal_interrupted _ | Budget_exhausted _ | Checkpoint_refused _ -> `Error
  | Node_rerun_after_cut _ -> `Warning
  | Price_raise_refused _ | Terminal_named_next _ -> `Warning
  | _ -> `Info

let to_string = function
  | Traversal_started { graph; node } ->
      Printf.sprintf "traversal of graph %S started at node %S" graph node
  | Node_started { node; handler } -> Printf.sprintf "node %S (%s) started" node handler
  | Node_finished { node; handler } -> Printf.sprintf "node %S (%s) returned" node handler
  | Node_failed { node; handler; message; policy } ->
      Printf.sprintf "node %S (%s) failed: %s [on_failure: %s]" node handler message
        (Definition.string_of_on_failure policy)
  | Price_set { node; price } -> Printf.sprintf "node %S set the price to %d" node price
  | Price_lowered { node; before; after } ->
      Printf.sprintf "node %S lowered the price from %d to %d" node before after
  | Price_raise_refused { node; asked; kept } ->
      Printf.sprintf "node %S asked for a price of %d, which is above the %d already announced; \
                      keeping %d"
        node asked kept kept
  | Terminal_named_next { node; ignored } ->
      Printf.sprintf "terminal node %S named %S as its successor; the traversal ends here anyway"
        node ignored
  | Budget_exhausted { node; budget } ->
      Printf.sprintf "node budget of %d reached before visiting %S" budget node
  | Traversal_resumed { graph; node; in_flight } ->
      Printf.sprintf "traversal of graph %S resumed at node %S, which %s" graph node
        (if in_flight then "was in flight when it was cut" else "had not started")
  | Node_rerun_after_cut { node } ->
      Printf.sprintf
        "node %S was in flight when the traversal was cut and is declared rerunnable: \
         running it again"
        node
  | Checkpoint_refused { node; message } ->
      Printf.sprintf "the checkpoint at node %S was refused: %s" node message
  | Traversal_completed { price; visited } ->
      Printf.sprintf "traversal completed after %d node(s), price %s" visited
        (match price with None -> "unset" | Some p -> string_of_int p)
  | Traversal_interrupted { node; reason } ->
      Printf.sprintf "traversal interrupted at node %S: %s" node reason
