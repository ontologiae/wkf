(** The most expensive path, computed before anything runs.

    A traversal's price is fixed once, by the first node that posts one -- in
    practice the entry node -- and the whole point of fixing it early is to be
    able to announce it. Which leaves the graph's author one obligation:

    {b the most expensive path through the graph must cost less than the price
    its entry node announces.}

    Otherwise there exists a path that is sold at a loss, and it will be taken
    eventually -- that is not a hypothesis, it is a path that exists.

    This is what acyclicity buys. On a DAG the most expensive path is a fold
    over the reverse topological order; on a graph that loops there is no such
    thing, and everything resting on that number collapses.

    @canonical Wkf.Cost *)

val open_nodes : Loaded.t -> string list
(** The nodes that {e must} route at runtime: not terminal, with no declared
    edge and no declared route. Nothing static can say where they go, so any
    bound computed from the declared graph stops being one as soon as a
    traversal reaches them. Declaring a node's routes closes it: the engine
    holds it to them, and the most expensive path counts them.

    They are not a mistake -- a routing node is the ordinary shape of an entry
    node -- but they are why {!check_price} has a third verdict. *)

val of_node : Loaded.t -> string -> int option
(** [of_node t name] is the cost of the most expensive path starting at [name],
    including [name]'s own [max_cost]. [None] if there is no such node.

    "Path" here means the declared edges and the fallback branches -- what the
    graph says. A handler that names its successor at runtime can build a path
    this number never saw; the node budget, not this function, is what stands
    behind that. *)

val from_start : Loaded.t -> int
val table : Loaded.t -> (string * int) list

type verdict =
  | Within of { cost : int; price : int }
  | Over of { cost : int; price : int }
  | Unbounded of { cost : int; price : int; routing : string list }
      (** The declared graph does not bound the traversal: at least one node
          reachable from the start has no declared edge, so its handler decides
          where to go and [cost] is only a lower bound.

          This is the honest answer rather than the reassuring one. A number
          that understates the worst path is worse than no number when money
          rides on it -- and the shape that produces it is the ordinary one: an
          entry node that routes, which is precisely the node that posts the
          price. *)

val check_price : Loaded.t -> price:int -> verdict
(** Compares the most expensive path from the entry node with the price that
    node announces. An {!Over} or {!Unbounded} verdict is a {e warning}, and the caller decides
    what to do with it: the engine knows neither the host's units nor its
    margin, so it cannot know that an overrun is deliberate. It can, on the
    other hand, refuse to keep quiet about it. *)

val string_of_verdict : verdict -> string
