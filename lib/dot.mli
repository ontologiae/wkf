(** Drawing the graph.

    A graph written in a database and never looked at is a graph whose shape
    nobody checks. This emits DOT, which [dot -Tsvg] turns into something one
    can read: the start node, the terminals, the declared edges, the fallback
    branches as dashed arrows, and the declared routes as dotted ones -- with a
    small "end" vertex when a route says a node may end the traversal. Routing
    by ["next"] from a node that declares no route cannot be drawn: it is
    written down nowhere.

    Every text that goes into a label (the title, node names, handler names,
    annotations) is escaped here: Graphviz labels take a double quote as the end
    of the label, and dot does not complain -- it draws something else.

    @canonical Wkf.Dot *)

val of_graph :
  ?name:string -> ?annotate:(Definition.node -> string list) -> Definition.t -> string
(** [name] is the title, the graph's name by default. [annotate] adds lines to
    a node's label under its name, handler and [max_cost] -- typically what its
    configuration says, which only the host knows how to read. *)

val of_loaded : ?name:string -> ?annotate:(Definition.node -> string list) -> Loaded.t -> string

val to_file :
  ?name:string -> ?annotate:(Definition.node -> string list) -> string -> Definition.t -> unit
