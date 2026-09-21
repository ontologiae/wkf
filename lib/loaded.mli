(** A graph that has been checked, and whose handlers have been resolved.

    This is the gate between {!Wkf.Graph} -- what someone wrote -- and
    {!Wkf.Engine} -- what runs. Everything that can be known before a traversal
    starts is decided here:

    - every node names a handler the registry knows (§ an unknown handler is an
      operations fault, not a runtime one: it means what is written is not what
      runs, and it must shout);
    - every node's configuration has been read by that handler, so a malformed
      one is seen when the graph is posted, not in the middle of a traversal
      someone is waiting for;
    - the graph is acyclic, and a cycle is a refusal that {e names the nodes of
      the cycle} -- "this graph has a cycle" helps nobody fix it;
    - exactly one node starts the traversal;
    - no edge and no fallback branch leaves the graph.

    What cannot be an error is a warning: a node nothing points at is usually a
    forgotten edge, but writing a graph in pieces is legitimate, so the loader
    says it rather than refusing it.

    @canonical Wkf.Loaded *)

type node = private {
  definition : Definition.node;
  run : Registry.runner;  (** the handler, with its configuration already read *)
  edge : string option;  (** the declared successor, if there is one *)
}

type t

type error =
  | No_start_node
  | Several_start_nodes of string list
  | Duplicate_node of string
  | Unknown_handler of { node : string; handler : string }
  | Bad_config of { node : string; handler : string; message : string }
  | Unknown_edge_endpoint of { from_ : string; to_ : string; missing : string }
  | Several_edges_from of string
      (** One outgoing edge per node. Several would be a condition table by
          another door, and the choice belongs to the handlers. *)
  | Unknown_failure_target of { node : string; target : string }
  | Divert_without_target of string
  | Non_positive_node_budget of int
  | Cycle of string list  (** the nodes of the cycle, named *)

type warning =
  | Unreachable_node of string
      (** No edge and no fallback branch leads to it, and it is not the start.
          Only what is written down counts: a handler naming it at run time is
          invisible to any static check, so on a routing graph expect this
          warning on the nodes the entry node routes to, and read it for what
          it is. *)
  | Terminal_with_edge of string
  | No_way_out of string
      (** A non-terminal node with no outgoing edge. Legitimate when its
          handler always names its own successor; a dead end otherwise, and the
          traversal will say so when it gets there. *)

val string_of_error : error -> string
val string_of_warning : warning -> string

val of_graph :
  ?registry:Registry.t -> Definition.t -> (t * warning list, error list) result
(** Checks everything at once and reports {e all} the errors, not the first:
    fixing a graph one refusal at a time is how an afternoon goes. *)

val graph : t -> Definition.t
val start : t -> string
val find : t -> string -> node option
val node_names : t -> string list

val successors : t -> string -> string list
(** The declared edge and the fallback branch, which is what the static checks
    and {!Wkf.Cost} see. Routing by ["next"] is invisible to them by
    construction: a handler may name any node, and the node budget is what
    stands behind that. *)
