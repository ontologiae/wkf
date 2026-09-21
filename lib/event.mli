(** What a traversal says while it runs.

    The engine emits; where events go is none of its business -- that is the
    host's log. The one guarantee it makes is that {b a failure is always
    reported}, whatever the node's policy: [`Continue] means "the traversal
    goes on", never "we don't mention it".

    @canonical Wkf.Event *)

type t =
  | Traversal_started of { graph : string; node : string }
  | Node_started of { node : string; handler : string }
  | Node_finished of { node : string; handler : string }
  | Node_failed of {
      node : string;
      handler : string;
      message : string;
      policy : Definition.on_failure;
    }
  | Price_set of { node : string; price : int }
  | Price_lowered of { node : string; before : int; after : int }
  | Price_raise_refused of { node : string; asked : int; kept : int }
      (** A node tried to raise the price. One may deliver cheaper than
          promised; one may not deliver dearer. The engine keeps the promise
          and says that it did. *)
  | Terminal_named_next of { node : string; ignored : string }
  | Budget_exhausted of { node : string; budget : int }
  | Traversal_resumed of { graph : string; node : string; in_flight : bool }
  | Node_rerun_after_cut of { node : string }
  | Checkpoint_refused of { node : string; message : string }
  | Traversal_completed of { price : int option; visited : int }
  | Traversal_interrupted of { node : string; reason : string }

val level : t -> [ `Info | `Warning | `Error ]
val to_string : t -> string
