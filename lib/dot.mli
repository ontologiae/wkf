(** Drawing the graph.

    A graph written in a database and never looked at is a graph whose shape
    nobody checks. This emits DOT, which [dot -Tsvg] turns into something one
    can read: the start node, the terminals, the declared edges, and the
    fallback branches as dashed ones.

    @canonical Wkf.Dot *)

val of_graph : ?name:string -> Definition.t -> string
val of_loaded : ?name:string -> Loaded.t -> string
val to_file : ?name:string -> string -> Definition.t -> unit
