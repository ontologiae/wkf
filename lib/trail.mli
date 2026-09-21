(** What a traversal went through, in order.

    Every visited node leaves a step, failed ones included. The trail is
    returned for a completed traversal {e and} for an interrupted one -- the
    interrupted one is precisely the one someone will want to read back, and
    dropping it to "keep things clean" would erase the only thing that says
    why.

    It is also what a resumed traversal starts from: the trail is carried in
    {!Wkf.State.t}, so a service that comes back up knows what was already
    done.

    @canonical Wkf.Trail *)

type step = State_t.step = {
  node : string;
  handler : string;
  output : Yojson.Safe.t;
      (** What the handler returned, reserved fields included. [{}] for a node
          that failed under a [`Continue] policy: it is deemed to have returned
          nothing. *)
  failure : string option;  (** the message, if this node failed *)
}

type t = step list

val steps : t -> step list
val visited : t -> string list
val last : t -> step option

val output : t -> string -> Yojson.Safe.t option
(** The output of the most recent visit to a node, if it was visited. *)

val to_json : t -> Yojson.Safe.t
(** The trail as JSON, for a host that keeps it in a [jsonb] column. Which is
    the point of leaving a handler's output free: measuring a traversal becomes
    a query, not a migration. *)
