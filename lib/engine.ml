type outcome =
  | Completed of { trail : Trail.t; price : int option }
  | Interrupted of { trail : Trail.t; node : string; reason : string }

type checkpoint = State.t -> (unit, string) result Lwt.t

let field json key =
  match json with `Assoc fields -> List.assoc_opt key fields | _ -> None

(* [run] and [resume] are the same walk; they differ only in where it starts
   and in what it does with the node that was in flight when a service was
   cut. *)
let walk ?(on_event = fun _ -> ()) ?checkpoint loaded ~context ~entry ~trail0 ~price0 ~visited0 =
  let open Lwt.Syntax in
  let graph = Loaded.graph loaded in
  let budget = graph.node_budget in
  let trail = ref (List.rev trail0) (* kept reversed while walking *)
  and price = ref price0
  and visited = ref visited0 in
  let push step = trail := step :: !trail in
  let state ?node ?reason status =
    {
      State.graph = graph.name;
      status;
      node;
      trail = List.rev !trail;
      price = !price;
      visited = !visited;
      context;
      reason;
    }
  in
  (* A checkpoint that has not landed is not a checkpoint: the walk waits for
     it, and gives up if it was refused. *)
  let save ?node ?reason status =
    match checkpoint with
    | None -> Lwt.return (Ok ())
    | Some write ->
        Lwt.catch
          (fun () -> write (state ?node ?reason status))
          (fun exn -> Lwt.return (Error (Printexc.to_string exn)))
  in
  let interrupted node reason =
    on_event (Event.Traversal_interrupted { node; reason });
    (* best effort: if the checkpoint is what failed, this will fail too, and
       there is nothing further to try *)
    let* _ = save ~node ~reason `Interrupted in
    Lwt.return (Interrupted { trail = List.rev !trail; node; reason })
  in
  let refused node message =
    let reason = Printf.sprintf "checkpoint refused: %s" message in
    on_event (Event.Checkpoint_refused { node; message });
    on_event (Event.Traversal_interrupted { node; reason });
    Lwt.return (Interrupted { trail = List.rev !trail; node; reason })
  in
  let completed node =
    on_event (Event.Traversal_completed { price = !price; visited = !visited });
    let* saved = save ~node `Completed in
    match saved with
    | Ok () -> Lwt.return (Completed { trail = List.rev !trail; price = !price })
    | Error message ->
        (* The work is done, and nothing can record that it is. Reporting it as
           completed would have the host bill a traversal its own books do not
           know about. *)
        refused node message
  in
  let checkpointed ?node status k =
    let* saved = save ?node status in
    match saved with
    | Ok () -> k ()
    | Error message -> refused (Option.value node ~default:"") message
  in
  (* The price is fixed by the first node that posts one, and a later node may
     only lower it. One may deliver cheaper than promised; one may not deliver
     dearer -- an announced price that could still rise would not be an
     announcement. *)
  let apply_price node output =
    match field output "price" with
    | None -> Ok ()
    | Some (`Int asked) -> (
        match !price with
        | None ->
            price := Some asked;
            on_event (Event.Price_set { node; price = asked });
            Ok ()
        | Some current when asked < current ->
            price := Some asked;
            on_event (Event.Price_lowered { node; before = current; after = asked });
            Ok ()
        | Some current when asked > current ->
            on_event (Event.Price_raise_refused { node; asked; kept = current });
            Ok ()
        | Some _ -> Ok ())
    | Some other ->
        Error
          (Printf.sprintf "reserved field \"price\" is %s, and an integer was expected"
             (Yojson.Safe.to_string other))
  in
  let rec visit name =
    if !visited >= budget then (
      on_event (Event.Budget_exhausted { node = name; budget });
      interrupted name (Printf.sprintf "node budget of %d exhausted" budget))
    else
      match Loaded.find loaded name with
      (* Only reachable through routing: the loader checked every declared edge
         and every fallback branch. A handler, on the other hand, may name
         anything. *)
      | None -> interrupted name (Printf.sprintf "no node named %S in this graph" name)
      | Some node ->
          incr visited;
          (* The in-flight marker, written before the work starts. It is the
             whole difference between "n was interrupted mid-work" and "n had
             not started". *)
          checkpointed ~node:name `Running (fun () -> execute name node)
  and execute name (node : Loaded.node) =
    let def = node.definition in
    on_event (Event.Node_started { node = name; handler = def.handler });
    let* result =
      Lwt.catch
        (fun () -> node.run ~context)
        (fun exn -> Lwt.return (Error (Printexc.to_string exn)))
    in
    match result with
    | Error message -> failed name node ~output:(`Assoc []) message
    | Ok output -> (
        match field output "failure" with
        | Some (`String message) -> failed name node ~output message
        | Some other ->
            interrupted name
              (Printf.sprintf "reserved field \"failure\" is %s, and a string was expected"
                 (Yojson.Safe.to_string other))
        | None -> succeeded name node output)
  and succeeded name (node : Loaded.node) output =
    let def = node.definition in
    on_event (Event.Node_finished { node = name; handler = def.handler });
    push { Trail.node = name; handler = def.handler; output; failure = None };
    match apply_price name output with
    | Error reason -> interrupted name reason
    | Ok () -> (
        (* A node routes when its output names the next one, whatever the
           declared edge says. That is all there is to routing: there is no
           node nature for it. *)
        match field output "next" with
        | Some (`String next) ->
            if def.terminal then (
              on_event (Event.Terminal_named_next { node = name; ignored = next });
              completed name)
            else go name next
        | Some `Null -> completed name
        | Some other ->
            interrupted name
              (Printf.sprintf
                 "reserved field \"next\" is %s, and a node name or null was expected"
                 (Yojson.Safe.to_string other))
        | None -> if def.terminal then completed name else follow name node)
  and failed name (node : Loaded.node) ~output message =
    let def = node.definition in
    (* Always, whatever the policy: "carry on" means the traversal goes on,
       never that we do not mention it. *)
    on_event
      (Event.Node_failed { node = name; handler = def.handler; message; policy = def.on_failure });
    push { Trail.node = name; handler = def.handler; output; failure = Some message };
    match def.on_failure with
    | `Stop -> interrupted name message
    | `Continue ->
        (* The node is deemed to have returned nothing: no price, no successor
           of its own, just the declared edge. *)
        if def.terminal then completed name else follow name node
    | `Divert -> (
        match def.failure_target with
        | Some target -> go name target
        | None -> interrupted name "set to divert on failure but names no failure_target")
  and follow name (node : Loaded.node) =
    match node.edge with
    | Some next -> go name next
    | None ->
        interrupted name
          "the node is not terminal, has no outgoing edge, and its handler named no successor"
  (* Between two nodes, nothing is in flight, and that is worth writing down:
     a service that comes back to this point resumes with nothing lost and
     nothing repeated. *)
  and go _from next = checkpointed ~node:next `Ready (fun () -> visit next)
  in
  match entry with
  | `At name -> checkpointed ~node:name `Ready (fun () -> visit name)
  | `In_flight name -> (
      match Loaded.find loaded name with
      | None -> interrupted name (Printf.sprintf "no node named %S in this graph" name)
      | Some node -> (
          match node.definition.on_resume with
          | `Rerun ->
              on_event (Event.Node_rerun_after_cut { node = name });
              visit name
          | `Fail ->
              (* The work it had started may or may not have reached the
                 outside world; nothing here can know. Deeming it failed is the
                 choice that does not make an effect happen twice, and the
                 node's own policy takes it from there. *)
              failed name node ~output:(`Assoc [])
                "the node was in flight when the traversal was cut"))

let run ?on_event ?checkpoint loaded ~context =
  let open Lwt.Syntax in
  let start = Loaded.start loaded in
  (match on_event with
  | Some f -> f (Event.Traversal_started { graph = (Loaded.graph loaded).name; node = start })
  | None -> ());
  let* outcome =
    walk ?on_event ?checkpoint loaded ~context ~entry:(`At start) ~trail0:[] ~price0:None
      ~visited0:0
  in
  Lwt.return outcome

let resume ?on_event ?checkpoint ?context loaded (state : State.t) =
  match State.check loaded state with
  | Error mismatch -> Lwt.return (Error mismatch)
  | Ok node ->
      let open Lwt.Syntax in
      let context = Option.value context ~default:state.context in
      let in_flight = state.status = `Running in
      (match on_event with
      | Some f -> f (Event.Traversal_resumed { graph = state.graph; node; in_flight })
      | None -> ());
      let entry = if in_flight then `In_flight node else `At node in
      let* outcome =
        walk ?on_event ?checkpoint loaded ~context ~entry ~trail0:state.trail
          ~price0:state.price ~visited0:state.visited
      in
      Lwt.return (Ok outcome)

let string_of_outcome = function
  | Completed { trail; price } ->
      Printf.sprintf "completed through %s, price %s"
        (String.concat " -> " (Trail.visited trail))
        (match price with None -> "unset" | Some p -> string_of_int p)
  | Interrupted { trail; node; reason } ->
      Printf.sprintf "interrupted at %S (%s) after %s" node reason
        (String.concat " -> " (Trail.visited trail))
