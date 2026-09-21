(lang dune 3.5)

(name wkf)

(generate_opam_files true)

(source
 (github ontologiae/ocaml_wkf))

(authors "Pierre-Alexandre Voye")
(maintainers "Pierre-Alexandre Voye")
(license MIT)

(package
 (name wkf)
 (synopsis "A flat DAG workflow engine whose nodes are registered handlers")
 (description
  "wkf executes an acyclic, flat graph of nodes. A node is a call to a handler \
   registered by the host; a node routes when its output names the next one. \
   The engine owns no storage, no billing, no logging and no domain type: it \
   consumes a graph that has already been read, carries an opaque context, and \
   returns the trail of what it visited -- for a completed traversal as well as \
   for an interrupted one. Acyclicity is checked when the graph is loaded (the \
   refusal names the nodes of the cycle) and the most expensive path through \
   the DAG can be computed before anything runs.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.5))
  lwt
  yojson
  atdgen-runtime
  (atdgen
   (and
    (>= 2.0)
    :build))
  (ocamlgraph (>= 2.0))
  (alcotest :with-test)))
