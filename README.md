# wkf — a flat DAG workflow engine for OCaml

An execution graph, defined outside the program, whose nodes call registered
functions and some of which decide where to go next.

```ocaml
Wkf.Registry.register (module My_handler);

let graph  = Result.get_ok (Wkf.Graph.of_json_string json) in
let loaded, warnings = Result.get_ok (Wkf.Loaded.of_graph graph) in
let%lwt outcome =
  Wkf.Engine.run loaded
    ~context:(`Assoc [ "ask", `String "…" ])
    (* written down at every node boundary, so a cut service can pick it up *)
    ~checkpoint:(fun state -> Db.save ~id (Wkf.State.to_json_string state))
in
match outcome with
| Wkf.Engine.Completed   { trail; price } -> commit trail price
| Wkf.Engine.Interrupted { trail; node; reason } -> log trail node reason
```

Most of what this library is worth is in what it does **not** do.

* **It is not a statechart.** No nested states, no parallel regions, no history
  states, no inter-level transitions. Each of those solves a real problem, and
  each costs an execution semantics one can no longer read and corner cases one
  can no longer test. This runs a flat, acyclic graph.
* **It knows nothing about your domain.** No database, no HTTP framework, no
  billing, no model provider, no user. A node is a call to a handler; what
  tells a node that queries a language model from a node that computes
  something is the handler, not the engine. Changing what a node calls is a
  change in your code and nowhere else.
* **It stores nothing.** It consumes a graph that has already been read, and
  returns a trail your own transaction commits — or does not.

Its dependencies are `lwt`, `yojson`, `atdgen-runtime` and `ocamlgraph`, and
they were counted before being taken: they become the dependencies of whoever
installs this.

## Installing

Not on opam yet. Locally:

```sh
opam pin add wkf . --kind=path     # or: opam pin add wkf git+file:///path/to/ocaml_wkf#main
```

and then, in the consuming project:

```lisp
(libraries wkf)
```

The SQL schema is not applied by the library. It is installed as a file, at
`$(opam var share)/wkf/wkf.sql`, and it is yours to apply.

## The ten things worth knowing

**1. A node is a call to a handler, and there is only one kind of node.** The
alternative — a "model call" nature, a "computation" nature, a "routing"
nature, each handled inside the engine — was passed over. Adding a kind of work
is registering a handler, not changing the engine.

**2. Routing is not a nature of its own.** A node routes when its output names
the next one:

| output | what the engine does |
| --- | --- |
| `{ "next": "n" }` | go to node `n`, whatever the declared edge says |
| `{ "next": null }` | the traversal ends here, with no terminal |
| `{ }` | follow the edge declared in the graph |

A decision function and a computing function are therefore the same object, and
a function that computes *and then* decides is not a special case.

**3. A handler's output is free, apart from three reserved fields** — `next`,
`price` and `failure`. Everything else is opaque to the engine and kept in the
trail. That is what lets you measure a traversal without the engine having had
to plan for the measurement: a handler returns its confidence, its cost, what
it read, and that becomes a query over `jsonb` rather than a migration.

**4. That same trail is also handed back to every later handler**, alongside
the context. `context` is fixed once by the host, before the traversal starts;
`trail` is the engine's own, built as it walks, and it is where a decisional
node's result reaches a downstream node that needs to *use* it, not just be
routed by it — `Wkf.Trail.output trail "that_node"`, a typed lookup rather than
a template string resolved at run time. See "Writing a handler" below.

**5. The base names, the code does.** A node carries the *name* of a handler,
looked up in a registry you filled at startup. This is what stands in place of
an expression language stored in the database: what is stored is a name and
data, never code. A name is checked when the graph is loaded; an expression is
only checked by running it, on a real traversal, at someone's expense. An
unknown handler is an operations fault — it means what is written is not what
runs — and it shouts rather than falling back.

**6. Everything checkable is checked when the graph is loaded**, not during a
traversal someone is waiting for: handler names, every node's configuration
(each handler reads its own, so a malformed one is refused by field name),
exactly one start, no edge or fallback branch leaving the graph, and
acyclicity — where the refusal **names the nodes of the cycle**, because "this
graph has a cycle" helps nobody fix it. What cannot be an error is a warning:
an unreachable node is usually a forgotten edge, but writing a graph in pieces
is legitimate.

**7. The failure policy belongs to the node**, not to the engine: `stop`
(the default), `continue`, `divert` to a fallback branch. The default is the
safe one — an engine that carries on by default turns every outage into a
silent degradation; you have to *write* `continue` to get it. A failure is
logged whatever the policy: "carry on" means the traversal goes on, never that
we do not mention it.

**8. The price is fixed once, by the first node that posts one**, and a later
node may only lower it. One may deliver cheaper than promised; one may not
deliver dearer. It is never accumulated, because a price known only at the end
cannot be announced at the start. The engine does not know what the number
means: it carries an integer and hands it back.

`Wkf.Cost` computes the most expensive path through the declared graph, so that
you can check it against the price your entry node announces before selling it.
**And it tells you when it cannot**: if a node reachable from the start has no
declared edge, its handler decides where to go, nothing written down bounds the
traversal, and the verdict says so and names that node rather than handing back
a number that understates the worst path. Since the entry node is typically
both the one that posts the price and the one that routes, expect that verdict
and read it as what it is — the bound has to come from somewhere else, such as
per-node costs plus a node budget you trust.

**9. A traversal is a transaction for your state and for the price, never for
side effects that have already left.** A node that called an outside service
consumed something there, and no rollback gives it back: a traversal aborted
after three expensive nodes *cost* three expensive nodes. There is no automatic
compensation and there will not be — a per-node undo asks every handler to know
how to unmake what it did, which is false for most of them. Better said than
simulated. The cost of an aborted traversal is a line of loss, not an error
case.

The trail comes back in **both** cases, completed and interrupted. The
interrupted one is precisely the one you will want to read back; dropping it to
keep things clean would erase the only thing that says why.

**10. A traversal writes itself down as it goes, so that a service which was cut
can pick it up.** That is the other half of point 9: since work that has
already left cannot be given back, the next best thing is not to do it twice.
Pass a `checkpoint` to `Wkf.Engine.run` and the engine hands it a
`Wkf.State.t` at every node boundary; `Wkf.Engine.resume` takes that state back
and carries on, with the trail, the price and the visit count intact.

The engine still writes nothing itself — it builds a value and hands it over,
and where it goes is your business. `schema/wkf.sql` has the tables for hosts
who keep it in PostgreSQL, along with `wkf_save_state()` (one call per
checkpoint), `wkf_traversal_state()` (the state, ready for `resume`) and the
`wkf_resumable` view (what a service reads when it comes back up).

There are two writes per node, and the pair is what makes a resume worth
anything:

| state | what a restarting service learns |
| --- | --- |
| `ready` at n | nothing was in flight; run n, and nothing is lost or repeated |
| `running` at n | n was working when the cut happened, and how far it got is unknowable |

What becomes of that in-flight node is the one thing the engine cannot decide,
so it is written in the graph. `on_resume` defaults to `fail`: the node is
deemed to have failed — with a message saying it was cut — and its own
`on_failure` takes it from there, which for a node that diverts means its
fallback branch. Write `on_resume: "rerun"` and it is simply done again, which
is right exactly when its work is idempotent. The default is the one that does
not make an effect happen twice; you have to *say* that repeating is safe.

A checkpoint that does not land is not a checkpoint: if yours returns `Error`
or raises, the traversal is interrupted, naming the node and the message. That
includes the final one — a traversal whose completion could not be written down
comes back interrupted and therefore unbilled, with its trail intact, rather
than having you bill for something your own books never recorded.

## What you provide

| you provide | why the engine cannot |
| --- | --- |
| the storage of the graph | it does not know your database — it consumes a graph already read |
| the handlers | that is all the useful work |
| the context | what a traversal needs to know belongs to your application |
| the billing | the engine carries an integer called a price and knows nothing more |
| the log | it emits events; where they go is not its business |
| the transaction | it is your database and your transaction |
| the checkpoint | the engine builds the state of a traversal; writing it down is your database again |
| a traversal's identity | integer, UUID, composite key — your schema decided that long ago, so the engine has no opinion |

The context is carried and never read, completed or validated by the engine.
That is deliberate: a context typed by the engine would force the engine to
know what your application puts in it. The price is that the engine guarantees
nothing about the context — each handler guarantees the part that concerns it.

## Writing a handler

```ocaml
module Draft = struct
  let name = "draft"

  type config = Draft_cfg_t.config   (* generated by atdgen from your own .atd *)

  (* Raise on a malformed configuration, naming the field. It is called once
     per node when the graph is loaded, never during a traversal. *)
  let read_config = Wkf.Registry.of_string_reader Draft_cfg_j.config_of_string

  let run ~config ~context ~trail =
    let open Lwt.Syntax in
    let* text = call_whatever_you_like ~model:config.model ~context in
    Lwt.return (Ok (`Assoc [ "text", `String text; "characters", `Int (String.length text) ]))
end
```

Typing the configuration in ATD is a recommendation, not an obligation —
`read_config` takes a `Yojson.Safe.t` and may do as it pleases, as long as it
raises with a message that names what is wrong. But `jsonb` accepts anything,
and a generated reader is what turns that into a refusal one can act on.

`context` and `trail` are two different channels, and the difference is when
each was fixed. `context` is built by the host once, before the traversal
starts, and stays identical for every node. `trail` is the engine's own: the
steps already visited in this traversal, in order, never including the node
that is currently running (it has not returned yet). A decisional node that
computes a value the rest of the pipeline must *use* — not just "go left or
go right" — puts it in its own output, and a node further down reads it with
`Wkf.Trail.output trail "that_node"`:

```ocaml
let run ~config:_ ~context:_ ~trail =
  match Wkf.Trail.output trail "triage" with
  | Some (`Assoc fields) -> (* whatever "triage" returned *) ...
  | _ -> ...
```

This is a plain OCaml lookup, typed and checked by the compiler, not a
template string resolved at run time (`{{steps.triage.outputs.x}}`, in the
style of Argo Workflows) — the engine's rule against an expression language
living in the database (see the spec, §11) applies here too: a string that is
only checked by running it is exactly what this avoids.

## The graph

Either as JSON (`Wkf.Graph.of_json_string`):

```json
{ "name": "one_turn",
  "node_budget": 20,
  "nodes": [
    { "name": "triage", "handler": "triage", "start": true, "max_cost": 1,
      "config": { "threshold": 40 } },
    { "name": "study", "handler": "work", "max_cost": 25,
      "on_failure": "divert", "failure_target": "note",
      "on_resume": "rerun",
      "config": { "label": "the long answer" } },
    { "name": "note", "handler": "work", "max_cost": 8, "config": {} },
    { "name": "done", "handler": "work", "terminal": true }
  ],
  "edges": [ { "from": "study", "to": "done" },
             { "from": "note",  "to": "done" } ],
  "routes": [ { "from": "triage", "to": "study" },
              { "from": "triage", "to": "note" } ] }
```

`routes` is optional. It declares where a node's handler *may* send the
traversal through `"next"` -- a route without `"to"` says it may end it with
`"next": null`. A route is never taken by default; the declared edge stays the
only default. Once a node declares routes, the cycle check, the most expensive
path, the orphan warning and the drawing all see them, and the engine holds the
handler to them: naming an undeclared node, or ending when no route says it
may, interrupts the traversal with the name of what was not declared. A node
that declares no route routes freely, as before. In OCaml the route fields are
`from_node` and `to_node`, so that `{ Wkf.Graph.from_; to_ }` still builds an
edge.

or built in OCaml — the types are records, `Wkf.Graph.node` and
`Wkf.Graph.graph`, and nothing forces you through JSON.

The PostgreSQL schema in `schema/wkf.sql` holds the same thing, with composite
foreign keys that stop an edge or a fallback branch from leaving its graph
(refused on write, not detected in OCaml), and a partial unique index that
allows exactly one start per graph. The `wkf_graph_json(text)` function it
defines returns a graph in exactly the JSON above, so reading a graph from
PostgreSQL is one query and no mapping code.

The schema can be applied again on a database that already has it (enum types
are created in `DO` blocks), which is how a host picks up a table a newer
version adds -- `wkf_route`, for the declared routes.

`Wkf.Dot.to_file` writes the graph as DOT. A graph written in a database and
never looked at is a graph whose shape nobody checks. Routes are dotted arrows,
the end of a traversal a small `end` vertex, and `?annotate` adds the host's own
lines to a node's label -- what its configuration says, which only the host
knows how to read. Every label is escaped: Graphviz takes a double quote as the
end of a label, and does not complain.

## Running the example, and the tests

```sh
dune exec example/demo.exe    # loads, checks, prices, draws and walks a graph twice
dune exec example/cut.exe     # a traversal cut mid-node, and picked up again
dune runtest
```

## Design notes

`SPEC-workflow.md`, in this repository, is the specification this library was
written from — including the alternatives that were weighed and dropped, and
why. It is in French; the library, being meant to be published, is in English.

## Licence

MIT.
