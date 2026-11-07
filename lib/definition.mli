(** The graph as it is written down.

    This is a plain description: it has not been checked, no handler has been
    resolved and no configuration has been read. {!Wkf.Loaded.of_graph} is what
    turns it into something runnable, and what refuses it by name when it is
    wrong.

    The types are the ones atdgen generates from [definition.atd]; they are
    re-exported here so that a user can build a graph in OCaml as easily as
    read one from JSON.

    @canonical Wkf.Graph *)

type on_failure = Definition_t.on_failure

type on_resume = Definition_t.on_resume
(** What becomes of a node that was in flight when the service was cut.
    [`Fail] -- the default -- deems it to have failed and lets its own
    {!on_failure} decide; [`Rerun] says its work may simply be done again. *)

type node = Definition_t.node = {
  name : string;
  handler : string;  (** the name of a handler in the registry *)
  config : Yojson.Safe.t;  (** read by that handler, when the graph is loaded *)
  max_cost : int;  (** what this node can cost at worst, in the host's unit *)
  on_failure : on_failure;
  failure_target : string option;  (** where [`Divert] goes *)
  on_resume : on_resume;  (** what a resume does with it if it was in flight *)
  start : bool;
  terminal : bool;
}

type edge = Definition_t.edge = { from_ : string; to_ : string }

type route = Definition_t.route = { from_node : string; to_node : string option }
(** Where a node's handler may send the traversal through ["next"]; [to_node = None]
    says it may end the traversal there. A node that declares routes is held to
    them by the engine; one that declares none routes freely. *)

type graph = Definition_t.graph = {
  name : string;
  node_budget : int;  (** a traversal stops beyond this many visited nodes *)
  nodes : node list;
  edges : edge list;
  routes : route list;  (** declared, never followed by default *)
}

type t = graph

val node : t -> string -> node option
val node_names : t -> string list
val start_nodes : t -> node list

val routes_from : t -> string -> route list
(** The routes a node declares, in the order written. [[]] means it declares
    none -- which is not the same as declaring that it never routes. *)

val successor : t -> string -> string option
(** The declared edge out of a node, if it has one. A node may legitimately
    have none: a handler that always names its own successor does not need an
    edge -- though {!Wkf.Loaded.of_graph} warns about it, because far more
    often it is an edge someone forgot. *)

val of_json_string : string -> (t, string) result
(** Reads the JSON shape described by [definition.atd]. The error names the
    field that was refused, which is the whole reason this format is typed. *)

val to_json_string : ?pretty:bool -> t -> string

val string_of_on_failure : on_failure -> string
val string_of_on_resume : on_resume -> string
