(** The state of a traversal, and what it takes to pick one up again.

    The engine writes nothing -- that has not changed. What it does is build
    this at every node boundary and hand it to the checkpoint function the host
    passed to {!Wkf.Engine.run}; where it goes from there is the host's
    business, and [schema/wkf.sql] holds a table for hosts who keep it in
    PostgreSQL.

    {2 What a state is for}

    A service that is cut in the middle of a traversal leaves work half done.
    Without a state written down, all that is left is a row saying a traversal
    started and nothing saying how far it got, which means paying again for
    everything it had already paid for. With one, the traversal picks up where
    it was.

    {2 The two boundaries, and why there are two}

    A checkpoint is written {e before} a node runs, with status [`Running], and
    again once it has returned and the next node is known, with status
    [`Ready]. That is two writes per node, and collapsing them into one would
    lose exactly the distinction that matters when a service comes back up:

    - [`Ready] at node n: nothing was in flight. Resuming runs n, and nothing
      has been lost or repeated.
    - [`Running] at node n: n was working when the cut happened, and whether
      its work reached the outside world is not knowable from here. That is a
      decision, and it is written in the graph -- see {!Wkf.Graph.on_resume}.

    A host that would rather write once per node can debounce in its own
    checkpoint function; it will get the second behaviour on every cut.

    @canonical Wkf.State *)

type status = State_t.status
(** [`Running], [`Ready], [`Completed], [`Interrupted] or [`Suspended]. A
    suspended traversal waits, at the node named in [node], for its host to
    resume it; nothing is in flight. *)

type t = State_t.state = {
  graph : string;  (** the graph this traversal belongs to *)
  status : status;
  node : string option;  (** in flight, next to run, or where it ended *)
  trail : Trail.t;
  price : int option;
  visited : int;  (** carried across a resume, so the node budget still means something *)
  context : Yojson.Safe.t;
      (** The context the traversal was given, so that a service coming back up
          has all it needs. Drop it before writing if it holds what you would
          rather not keep, and hand it back yourself on resume. *)
  reason : string option;  (** why it was interrupted *)
}

val of_json_string : string -> (t, string) result
val to_json_string : ?pretty:bool -> t -> string
val string_of_status : status -> string

val is_resumable : t -> bool
(** True for [`Running], [`Ready] and [`Suspended]. A traversal that is over is
    over: picking one up again would run its nodes a second time. What resumes
    a suspended one is the host's decision, never a service restart: see
    [wkf_resumable] in [schema/wkf.sql], which lists only the first two. *)

type mismatch =
  | Other_graph of { state : string; graph : string }
  | Unknown_node of string
  | Nothing_to_resume of status
  | No_node

val check : Loaded.t -> t -> (string, mismatch) result
(** Checks that this state can be resumed against this graph, and returns the
    node it would resume at. A state resumed against another graph would walk a
    map of somewhere else. *)

val string_of_mismatch : mismatch -> string
