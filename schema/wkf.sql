-- The schema the engine expects a host to keep its graphs in.
--
-- It ships with the package and is applied by the host: the engine never
-- touches a database, and does not depend on one. What it consumes is a graph
-- that has already been read -- through the JSON of definition.atd, which the
-- wkf_graph_json function at the bottom of this file produces in one query.
--
-- Closed domains are enums rather than text: a closed domain belongs in the
-- type. The counterpart is assumed -- a new value is an ALTER TYPE ... ADD
-- VALUE, that is a migration, where a lookup table would have taken an INSERT.

create type wkf_on_failure as enum ('stop', 'continue', 'divert');

-- What to do with a node that was in flight when the service was cut. The
-- default is the safe one: work that may already have left is not made to
-- leave twice on the engine's own initiative.
create type wkf_on_resume as enum ('fail', 'rerun');

-- Where a traversal stands. 'ready' means nothing is in flight and the node
-- named is the one to run next; 'running' means that node was working when the
-- row was last written, which is what a service finds after a cut.
create type wkf_traversal_status as enum ('running', 'ready', 'completed', 'interrupted');

-- A graph is a row with an identity, not a name copied onto every node and
-- every edge. A text column copied around is relational in appearance only: no
-- table declares the graphs, so nothing stops a typo from creating a phantom
-- graph of one node, and the attributes of the whole -- its start, its budget,
-- whether it is live -- have nowhere to live.
create table if not exists wkf_graph (
  id          int generated always as identity primary key,
  name        text not null unique,
  -- The second net: beyond this many visited nodes a traversal stops, whatever
  -- happens. It catches what the acyclicity check missed.
  node_budget int not null default 50,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint node_budget_is_positive check (node_budget > 0)
);

-- A node: the name of a handler, its configuration, its failure policy.
create table if not exists wkf_node (
  id         int generated always as identity primary key,
  graph_id   int not null references wkf_graph(id) on delete cascade,
  name       text not null,              -- unique WITHIN its graph, not beyond
  -- The name of a handler in the registry. Checked when the graph is loaded;
  -- an unknown one is an operations fault that shouts, never a silent
  -- fallback.
  handler    text not null,
  -- The configuration, validated by the handler's own reader when the graph is
  -- loaded. jsonb gives the flexibility -- a new handler wanting a new
  -- parameter imposes a migration on nobody -- and the reader gives the
  -- validation jsonb has not.
  config     jsonb not null default '{}'::jsonb,
  -- What this node can cost AT WORST, in the host's unit. Feeds the most
  -- expensive path; the engine gives it no other meaning.
  max_cost   int not null default 0,
  on_failure wkf_on_failure not null default 'stop',
  failure_target int,
  on_resume  wkf_on_resume not null default 'fail',
  -- Where a traversal begins. One per graph, and the partial index below makes
  -- it so: two starts would be settled by the order of the execution plan,
  -- that is to say by nothing.
  is_start    boolean not null default false,
  is_terminal boolean not null default false,
  unique (graph_id, name),
  -- Not decorative: this key is what makes the composite foreign key below
  -- possible, and that foreign key is what STOPS a reference from leaving its
  -- graph. Without it a failure_target could name a node of another graph, and
  -- the traversal would change graph halfway.
  unique (graph_id, id),
  foreign key (graph_id, failure_target) references wkf_node (graph_id, id),
  -- "divert" with no destination is a row that lies: refused on write, rather
  -- than discovered the moment the node fails.
  constraint divert_has_a_destination
    check (on_failure <> 'divert' or failure_target is not null)
);

create unique index if not exists wkf_node_one_start
  on wkf_node (graph_id) where is_start;

-- An edge: where the traversal goes when the node did not name its successor
-- itself.
--
-- One outgoing edge per node, hence the primary key on from_node alone. The
-- choice belongs to the handlers, not to a table of conditions: several
-- conditional edges would be an expression language by another door.
--
-- graph_id is copied here for the same reason as above: it is what lets the
-- two composite foreign keys require both ends to belong to the SAME graph. An
-- edge between two graphs is not an error to detect in OCaml, it is a row to
-- refuse.
create table if not exists wkf_edge (
  graph_id  int not null,
  from_node int primary key,
  to_node   int not null,
  foreign key (graph_id, from_node) references wkf_node (graph_id, id) on delete cascade,
  foreign key (graph_id, to_node)   references wkf_node (graph_id, id) on delete cascade
);

-- What the schema cannot say:
--
--   * acyclicity is not expressible as a constraint. It is checked when the
--     graph is loaded, and that is where the refusal names the nodes of the
--     cycle;
--   * neither is reachability: nothing here stops an orphan node. That is not
--     a fault -- one writes a graph in pieces -- but it is a warning the
--     loading gives, because an unreachable node is nearly always a forgotten
--     edge.

-- The bridge to the engine: the graph as the JSON of definition.atd.
--
-- Note what it does with failure_target: the table holds a node id, the JSON
-- wants a node name, and the field is left out entirely when there is none --
-- an explicit null is not the same thing as an absent field to a typed reader.
create or replace function wkf_graph_json(p_graph text) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'name',        g.name,
    'node_budget', g.node_budget,
    'nodes', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'name',       n.name,
          'handler',    n.handler,
          'config',     n.config,
          'max_cost',   n.max_cost,
          'on_failure', n.on_failure::text,
          'on_resume',  n.on_resume::text,
          'start',      n.is_start,
          'terminal',   n.is_terminal)
        || case when t.name is null then '{}'::jsonb
                else jsonb_build_object('failure_target', t.name) end
        order by n.id)
      from wkf_node n
      left join wkf_node t on t.id = n.failure_target
      where n.graph_id = g.id), '[]'::jsonb),
    'edges', coalesce((
      select jsonb_agg(
        jsonb_build_object('from', a.name, 'to', b.name) order by a.id)
      from wkf_edge e
      join wkf_node a on a.id = e.from_node
      join wkf_node b on b.id = e.to_node
      where e.graph_id = g.id), '[]'::jsonb))
  from wkf_graph g
  where g.name = p_graph and g.active;
$$;


-- ---------------------------------------------------------------------------
-- What a traversal leaves behind while it runs.
--
-- The engine writes none of this: it builds a state at every node boundary and
-- hands it to a checkpoint function the host provided. These tables are where
-- that function puts it, and wkf_save_state below is the whole of it -- one
-- call per checkpoint.
--
-- The reason any of this exists: a service cut in the middle of a traversal
-- leaves work half done. Without a state written down, all that is left is a
-- row saying a traversal started and nothing saying how far it got, which
-- means paying a second time for everything already paid for. Side effects
-- that have already left cannot be given back (the engine says so plainly);
-- the next best thing is not to do them twice.

create table if not exists wkf_traversal (
  id         bigint generated always as identity primary key,
  graph_id   int not null references wkf_graph(id),
  status     wkf_traversal_status not null default 'ready',
  -- In flight, next to run, or where it ended, depending on the status.
  node       text,
  price      int,
  -- Carried across a resume, so that the graph's node budget means the same
  -- thing on both sides of the cut.
  visited    int not null default 0,
  -- What the traversal was given to work with. Drop it before writing if it
  -- holds what you would rather not keep -- the engine will take it as an
  -- argument on resume instead.
  context    jsonb not null default 'null'::jsonb,
  reason     text,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One row per visited node, appended and never updated. The trail could have
-- been a jsonb column on the row above, and it is one inside the state the
-- engine hands over; here it is rows, because a handler's output is free and
-- kept, and that is only worth anything if it can be queried.
create table if not exists wkf_traversal_step (
  traversal_id bigint not null references wkf_traversal(id) on delete cascade,
  seq          int not null,
  node         text not null,
  handler      text not null,
  output       jsonb not null default '{}'::jsonb,
  failure      text,
  at           timestamptz not null default now(),
  primary key (traversal_id, seq)
);

create index if not exists wkf_traversal_unfinished
  on wkf_traversal (graph_id, updated_at)
  where status in ('running', 'ready');

-- What a service reads when it comes back up: the traversals its own tables
-- still call live. Those in 'running' were cut mid-node; what becomes of that
-- node is written in wkf_node.on_resume, and the engine applies it.
create or replace view wkf_resumable as
  select t.id, g.name as graph, t.status, t.node, t.visited, t.price, t.updated_at
  from wkf_traversal t join wkf_graph g on g.id = t.graph_id
  where t.status in ('running', 'ready')
  order by t.updated_at;

-- Opening a traversal. The host keys it: the engine's state carries no
-- identity of its own, so that it owes nothing to how you name things.
create or replace function wkf_traversal_open(p_graph text, p_context jsonb default 'null'::jsonb)
returns bigint
language sql as $$
  insert into wkf_traversal (graph_id, status, context)
  select id, 'ready', p_context from wkf_graph where name = p_graph and active
  returning id;
$$;

-- The checkpoint, host side: takes the state the engine handed over and makes
-- the tables say the same thing. Steps are appended, never rewritten -- a
-- trail that could be edited would not be a trail.
create or replace function wkf_save_state(p_traversal bigint, p_state jsonb)
returns void
language plpgsql as $$
declare
  v_graph text;
  v_known int;
begin
  select g.name into v_graph
  from wkf_traversal t join wkf_graph g on g.id = t.graph_id
  where t.id = p_traversal;

  if v_graph is null then
    raise exception 'no traversal %', p_traversal;
  end if;
  -- A state saved against the wrong traversal would be a trail of somewhere
  -- else, and nothing downstream would notice.
  if v_graph <> (p_state ->> 'graph') then
    raise exception 'traversal % belongs to graph %, and this state to %',
      p_traversal, v_graph, p_state ->> 'graph';
  end if;

  update wkf_traversal set
    status     = (p_state ->> 'status')::wkf_traversal_status,
    node       = p_state ->> 'node',
    price      = (p_state ->> 'price')::int,
    visited    = coalesce((p_state ->> 'visited')::int, 0),
    context    = coalesce(p_state -> 'context', 'null'::jsonb),
    reason     = p_state ->> 'reason',
    updated_at = now()
  where id = p_traversal;

  select count(*) into v_known from wkf_traversal_step where traversal_id = p_traversal;

  insert into wkf_traversal_step (traversal_id, seq, node, handler, output, failure)
  select p_traversal, s.ord::int,
         s.step ->> 'node', s.step ->> 'handler',
         coalesce(s.step -> 'output', '{}'::jsonb), s.step ->> 'failure'
  from jsonb_array_elements(coalesce(p_state -> 'trail', '[]'::jsonb))
       with ordinality as s(step, ord)
  where s.ord > v_known;
end;
$$;

-- The other direction: the state as the engine's reader expects it, rebuilt
-- from the rows. This is what a service feeds to Wkf.Engine.resume.
--
-- Note what is left out rather than written as null: a typed reader is not the
-- same thing as jsonb, and an absent field is not a null one.
create or replace function wkf_traversal_state(p_traversal bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'graph',   g.name,
    'status',  t.status::text,
    'visited', t.visited,
    'context', t.context,
    'trail', coalesce((
      select jsonb_agg(
        jsonb_build_object('node', s.node, 'handler', s.handler, 'output', s.output)
        || case when s.failure is null then '{}'::jsonb
                else jsonb_build_object('failure', s.failure) end
        order by s.seq)
      from wkf_traversal_step s where s.traversal_id = t.id), '[]'::jsonb))
    || case when t.node   is null then '{}'::jsonb else jsonb_build_object('node', t.node) end
    || case when t.price  is null then '{}'::jsonb else jsonb_build_object('price', t.price) end
    || case when t.reason is null then '{}'::jsonb else jsonb_build_object('reason', t.reason) end
  from wkf_traversal t join wkf_graph g on g.id = t.graph_id
  where t.id = p_traversal;
$$;
