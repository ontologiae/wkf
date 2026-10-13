(** Running a traversal, and picking one up again.

    A traversal is one walk, from the entry node to a terminal. It does not
    loop. What loops is the application, which starts another traversal next
    time round -- and that cycle lives in the host, not in the graph.

    {2 What a traversal is a transaction for, and what it is not}

    It is one for the host's writes: the engine writes nothing itself. It
    returns a trail, and the host commits it -- or does not -- inside its own
    transaction. It is one for the price: a traversal that does not complete is
    not billed.

    It is not one for side effects that have already left. A node that called an
    outside service consumed something there, and no rollback gives it back. A
    traversal aborted after three expensive nodes {e cost} three expensive
    nodes. There is no automatic compensation and there will not be: a
    per-node undo asks every handler to know how to unmake what it did, which
    is false for most of them. Better said than simulated -- the cost of an
    aborted traversal is the host's, and it is a line of loss, not an error
    case.

    That last paragraph is also the argument for {!checkpoint}. Since aborted
    work cannot be given back, the next best thing is not to do it twice: a
    traversal whose state was written down at every node boundary resumes where
    it was, instead of paying again for everything it had already paid for.

    @canonical Wkf.Engine *)

type outcome =
  | Completed of { trail : Trail.t; price : int option }
  | Interrupted of { trail : Trail.t; node : string; reason : string }
      (** [node] is where it stopped. The trail is returned in {e both} cases. *)

type checkpoint = State.t -> (unit, string) result Lwt.t
(** Where the host writes the state of a traversal down.

    It is called before every node runs and again once that node has returned,
    and the traversal waits for it: a checkpoint that has not landed is not a
    checkpoint. If it returns [Error] or raises, the traversal is
    {!Interrupted}, naming the node and the message -- a traversal that carried
    on while nothing could record it would be spending money no one could
    account for afterwards, which is the thing this exists to prevent.

    That applies to the last checkpoint too: a traversal whose completion could
    not be written down comes back interrupted, and therefore unbilled. The
    trail is still returned, so nothing that was learned is lost. *)

val run :
  ?on_event:(Event.t -> unit) ->
  ?checkpoint:checkpoint ->
  Loaded.t ->
  context:Yojson.Safe.t ->
  outcome Lwt.t
(** Walks the graph from its start node.

    [context] is built by the host and handed to every handler untouched.
    Alongside it, every handler also receives the trail of what the nodes
    visited so far in this traversal returned -- see
    {!Registry.HANDLER.run}.

    A traversal ends when a terminal node has returned, when a handler names
    [`Null] as its successor, or -- as an interruption -- when a node fails
    under a [`Stop] policy, when a node has no way out, when a handler names a
    node that does not exist, when a handler breaks the contract on a reserved
    field, when a checkpoint could not be written, or when the graph's node
    budget is exhausted.

    [on_event] sees everything worth logging, a failure included whatever the
    node's policy. *)

val resume :
  ?on_event:(Event.t -> unit) ->
  ?checkpoint:checkpoint ->
  ?context:Yojson.Safe.t ->
  Loaded.t ->
  State.t ->
  (outcome, State.mismatch) result Lwt.t
(** Picks up a traversal a cut interrupted, from the state the host wrote down.

    The trail, the price and the number of nodes already visited come back with
    it, so the node budget means the same thing on both sides of the cut and
    what was already done is not done again.

    What happens to the node that was in flight is the one thing that cannot be
    decided here, and so it is decided in the graph
    ({!Wkf.Graph.on_resume}): [`Fail] -- the default -- deems it to have failed,
    with the message saying it was cut, and lets the node's own
    {!Wkf.Graph.on_failure} take it from there; [`Rerun] runs it again, which
    is right exactly when its work is idempotent.

    [context] defaults to the one the state carries.

    [Error] when the state does not belong to this graph, names a node the
    graph no longer has, or is already over -- see {!State.check}. *)

val string_of_outcome : outcome -> string
