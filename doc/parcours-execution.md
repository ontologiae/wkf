# Par où passe une traversée — visite du code

Document de travail, en français comme la spec, et pour la même raison : on le
relit dans sa langue. Le code qu'il visite est en anglais (§12.2).

La visite suit une exécution **réelle**, reproductible d'une commande :

```sh
dune exec example/demo.exe
```

Le graphe est celui d'`example/demo.ml:76-100`, et son nœud d'entrée est un
**nœud décisionnel** au sens du §2.2 : il ne se distingue en rien d'un autre
nœud, sinon que sa sortie nomme son suivant.

```
                         ┌──────────┐
                  ┌─────▶│  study   │─────┐        study : 25 au pire
  ┌────────┐      │      └──────────┘     ▼
  │ triage │──────┤                  ┌────────┐     ┌──────┐
  └────────┘      │      ┌──────────┐│ polish │────▶│ done │  (terminal)
   décide, et     └─────▶│   note   │└────────┘     └──────┘
   pose le prix          └──────────┘  échoue, et
                                       `continue`
   ─────▶  décidé à l'exécution (champ « next »)
   ─────   arête déclarée dans le graphe
```

La question posée fait 12 caractères, en dessous du seuil de 40 : `triage`
nommera `note`. Voici la sortie observée, et c'est elle que la visite déplie
ligne à ligne :

```
    info    traversal of graph "one_turn" started at node "triage"
    info    node "triage" (triage) started
    info    node "triage" (triage) returned
    info    node "triage" set the price to 10
    info    node "note" (work) started
    info    node "note" (work) returned
    info    node "polish" (work) started
    error   node "polish" (work) failed: the polish is unavailable [on_failure: continue]
    info    node "done" (work) started
    info    node "done" (work) returned
    info    traversal completed after 4 node(s), price 10
  => completed through triage -> note -> polish -> done, price 10
```

---

## Avant la traversée : trois choses qui n'arrivent qu'une fois

### 1. Le registre — `example/demo.ml:114`

```ocaml
Wkf.Registry.register (module Triage);
```

`register` (`lib/registry.ml:38`) refuse un nom déjà pris, puis appelle
`entry_of_module` (`lib/registry.ml:27`). Ce dernier **efface le type de la
configuration** : ce que la table garde n'est pas le module, c'est une fonction
qui transforme le JSON d'un nœud en une fermeture exécutable
(`lib/registry.ml:28-36`). C'est la seule forme qui laisse cohabiter dans une
même table des fonctions dont les configurations n'ont pas le même type.

Rien n'est exécuté ici. On enregistre de quoi exécuter plus tard.

### 2. Lire le graphe — `example/demo.ml:118`

`Wkf.Graph.of_json_string` (`lib/definition.ml:19`) délègue au lecteur engendré
par atdgen depuis `lib/definition.atd`, et rattrape ses trois exceptions pour en
faire un `Error` qui **nomme le champ fautif**. C'est tout l'intérêt d'avoir
typé le format plutôt que de lire un `Yojson.Safe.t` à la main.

À la sortie : des enregistrements OCaml, et rien de vérifié.

### 3. Charger — `example/demo.ml:123` → `lib/loaded.ml:118`

`Loaded.of_graph` est la porte entre « ce que quelqu'un a écrit » et « ce qui
s'exécute ». Tout ce qui est vérifiable l'est là, et **tous les refus sortent
ensemble** — corriger un graphe un refus à la fois, c'est comme ça qu'un
après-midi passe.

| étape | où | ce qu'elle fait |
| --- | --- | --- |
| `index_nodes` | `lib/loaded.ml:71` | table des nœuds par nom ; les doublons deviennent des erreurs |
| `index_edges` | `lib/loaded.ml:84` | arêtes par origine ; extrémité inconnue, deuxième arête sortante |
| `check_start` | `lib/loaded.ml:105` | exactement un départ |
| `check_failure_policy` | `lib/loaded.ml:111` | `divert` sans destination, destination inconnue |
| `Registry.prepare` | `lib/loaded.ml:133` | **le nom devient du code** (ci-dessous) |
| `Dag.of_definition` | `lib/loaded.ml:149` → `lib/dag.ml:21` | le graphe ocamlgraph : arêtes déclarées **et** branches de repli |
| `Dag.cycles` | `lib/loaded.ml:150` → `lib/dag.ml:42` | composantes fortement connexes : le refus **nomme** les nœuds du cycle |
| avertissements | `lib/loaded.ml:160-179` | orphelins, terminal avec arête, cul-de-sac |

Le passage du nom au code mérite d'être suivi, parce que c'est là que le §3.1
et le §4 se rejoignent :

```
lib/loaded.ml:133   Registry.prepare ~registry n.handler n.config
lib/registry.ml:52    cherche le nom dans la table       ← faute d'exploitation si absent
lib/registry.ml:29    appelle H.read_config              ← ici : example/demo.ml:29
lib/registry.ml:30    rend la fermeture (fun ~context -> H.run ~config ~context)
lib/loaded.ml:136     range { definition; run; edge } dans la table du graphe chargé
```

Deux conséquences qu'on ne voit qu'en suivant ce fil :

1. **la configuration est lue au chargement, pas à l'exécution.** Une
   configuration malformée est refusée quand on pose le graphe, pas au milieu
   d'une traversée que quelqu'un attend ;
2. **l'arête déclarée est résolue au chargement** aussi (`lib/loaded.ml:136`,
   le champ `edge`). Le moteur ne cherchera pas une arête pendant la traversée :
   elle est déjà dans le nœud.

### Et, avant de vendre : `Cost` — `example/demo.ml:132-136`

`Cost.table_of` (`lib/cost.ml:6`) plie l'ordre topologique inverse
(`lib/dag.ml:50`) : coût d'un nœud = le sien + le pire de ses successeurs.
`check_price` (`lib/cost.ml:58`) compare au prix annoncé — et sur ce graphe-ci
rend `Unbounded`, parce que `open_nodes` (`lib/cost.ml:36`) constate que le
nœud d'entrée n'a **aucune arête déclarée** : il route, donc rien d'écrit ne
borne la traversée. Le verdict le dit et nomme le nœud, plutôt que de rendre un
chiffre qui sous-estime.

---

## La traversée, nœud par nœud

`Wkf.Engine.run` (`lib/engine.ml:202`) émet `Traversal_started`, puis appelle
`walk` (`lib/engine.ml:13`) avec une trace vide, aucun prix, zéro nœud visité.
`run` et `resume` sont la **même** marche ; ils ne diffèrent que par l'entrée
(`lib/engine.ml:184`).

`walk` ouvre trois références — trace, prix, compteur (`lib/engine.ml:17-19`) —
et une poignée de fermetures locales. Ici, `checkpoint` n'est pas fourni : `save`
(`lib/engine.ml:35`) rend `Ok ()` immédiatement et n'écrit rien. Avec un point
de reprise, c'est là que la base serait écrite deux fois par nœud (voir
`example/cut.ml`).

### `triage` — le nœud décisionnel

```
lib/engine.ml:185   `At "triage"  → checkpointed `Ready  → visit "triage"
lib/engine.ml:100     !visited (0) < budget (20)                      ✓
lib/engine.ml:104     Loaded.find → le nœud préparé (lib/loaded.ml:186)
lib/engine.ml:110     incr visited                                    → 1
lib/engine.ml:114     checkpointed `Running  ← « ce nœud travaille »
lib/engine.ml:115   execute
lib/engine.ml:117     on_event Node_started       → « node "triage" (triage) started »
lib/engine.ml:119-121 Lwt.catch (node.run ~context)
                        ↳ example/demo.ml:31  Triage.run
                          lit "ask" dans le contexte, 12 < 40, donc « note »
                          rend { "next": "note", "price": 10, "asked_characters": 12 }
lib/engine.ml:126     field output "failure" → None
lib/engine.ml:133   succeeded
lib/engine.ml:135     on_event Node_finished      → « node "triage" (triage) returned »
lib/engine.ml:136     push : la sortie ENTIÈRE entre dans la trace, champs libres compris
lib/engine.ml:137     apply_price (lib/engine.ml:77) : prix vide → 10    → « set the price to 10 »
lib/engine.ml:143     field output "next" → `String "note"     ← LA DÉCISION
lib/engine.ml:148     go "triage" "note"
lib/engine.ml:182   go → checkpointed `Ready "note" → visit "note"
```

**C'est tout ce qu'est un nœud décisionnel.** Il n'y a pas de branche « nœud de
routage » dans le moteur ; il y a une lecture de champ, `lib/engine.ml:143`, et
elle a lieu pour tous les nœuds. Le graphe déclare pourtant une arête
`triage → ?` : non, justement, il n'en déclare aucune (`example/demo.ml:98-101`),
et c'est ce que `Cost` signalait plus haut. Si une arête existait, la ligne 148
l'emporterait quand même : le nœud décide, l'arête est le chemin par défaut.

Noter aussi ce que la ligne 137 impose : **le prix est appliqué avant le
routage**. Un nœud qui décide et qui tarife le fait dans la même sortie, et le
moteur traite les deux champs dans l'ordre — prix, puis suivant.

### `note` — le nœud qui ne décide rien

Même chemin jusqu'à `succeeded`, mais `Work.run` (`example/demo.ml:70`) rend
`{ "wrote": ... }` : pas de `next`.

```
lib/engine.ml:155   field "next" → None, et le nœud n'est pas terminal
lib/engine.ml:173   follow : node.edge — l'arête résolue au CHARGEMENT
lib/engine.ml:175   go "note" "polish"
```

### `polish` — celui qui échoue sans arrêter la traversée

`Work.run` rend `Error "the polish is unavailable"` (`example/demo.ml:71`).

```
lib/engine.ml:124   Error message → failed
lib/engine.ml:156 failed
lib/engine.ml:160   on_event Node_failed  ← TOUJOURS, quelle que soit la politique
lib/engine.ml:162   push : le nœud entre dans la trace avec son message
lib/engine.ml:163   match on_failure
lib/engine.ml:165     `Continue → réputé n'avoir rien rendu : ni prix, ni suivant à lui
lib/engine.ml:168     follow → l'arête déclarée → "done"
```

Les deux autres politiques partent des lignes 164 (`Stop` : la traversée
s'interrompt, trace rendue) et 169 (`Divert` : `go` vers `failure_target`, qui
est un `go` comme les autres — d'où le fait que la branche de repli compte dans
le chemin le plus cher et dans la détection de cycle).

### `done` — le terminal

```
lib/engine.ml:155   field "next" → None, et def.terminal = true
lib/engine.ml:56  completed
lib/engine.ml:57    on_event Traversal_completed → « after 4 node(s), price 10 »
lib/engine.ml:58    save `Completed — ici sans effet ; avec un point de reprise,
                    un refus d'écriture rendrait la traversée INTERROMPUE (lib/engine.ml:65)
lib/engine.ml:60    Completed { trail = List.rev !trail; price = !price }
```

L'hôte reçoit `Completed`, décide de facturer 10, et commet la trace dans **sa**
transaction. Le moteur, lui, n'a rien écrit nulle part.

---

## Récapitulatif : l'ordre d'appel, d'un seul tenant

```
example/demo.ml:114  Registry.register            registry.ml:38 → :27 (efface le type de config)
example/demo.ml:118  Graph.of_json_string         definition.ml:19 → definition_j (atdgen)
example/demo.ml:123  Loaded.of_graph              loaded.ml:118
                       index_nodes                loaded.ml:71
                       index_edges                loaded.ml:84
                       check_start                loaded.ml:105
                       check_failure_policy       loaded.ml:111
                       Registry.prepare           loaded.ml:133 → registry.ml:52 → :29 → :30
                       Dag.of_definition          loaded.ml:149 → dag.ml:21
                       Dag.cycles                 loaded.ml:150 → dag.ml:42 (ocamlgraph, SCC)
                       avertissements             loaded.ml:160-179
example/demo.ml:132  Cost.table                   cost.ml:6 → dag.ml:50 (ordre topologique)
example/demo.ml:136  Cost.check_price             cost.ml:58 → :36 (nœuds qui routent)
example/demo.ml:138  Dot.to_file                  dot.ml (ocamlgraph, Graphviz.Dot)
example/demo.ml:146  Engine.run                   engine.ml:202 → walk engine.ml:13
                       entrée                     engine.ml:185
                       visit                      engine.ml:99   (plafond, find, compteur)
                       execute                    engine.ml:115  (Lwt.catch, la fonction)
                       succeeded                  engine.ml:133  (trace, prix, DÉCISION :143)
                       follow                     engine.ml:173  (arête déclarée)
                       failed                     engine.ml:156  (stop / continue / divert)
                       completed                  engine.ml:56
```

## Les deux chemins que cette visite n'emprunte pas

- **le point de reprise et la reprise** : `lib/engine.ml:35` (`save`),
  `lib/engine.ml:67` (`checkpointed`), `lib/engine.ml:186` (l'entrée `In_flight`)
  et `lib/engine.ml:214` (`resume`). `dune exec example/cut.exe` les parcourt,
  coupure comprise ;
- **les refus** : tout ce que `Loaded.of_graph` peut rendre en `Error`, et les
  interruptions du §7. La suite de tests les prend un par un
  (`test/test_wkf.ml`).

## Ce que la visite dit du dessin d'ensemble

Trois choses se voient mieux en suivant le fil qu'en lisant la spec :

1. **Le moteur ne décide rien.** Il lit un champ (`engine.ml:143`), consulte une
   colonne (`engine.ml:163`), suit une arête déjà résolue (`engine.ml:174`). Les
   décisions sont dans le graphe et dans les fonctions.
2. **Tout ce qui peut échouer tôt échoue au chargement.** Pendant la traversée,
   il ne reste que ce qui dépend vraiment de l'exécution : ce qu'une fonction
   rend, et ce que ça coûte.
3. **Une seule marche pour deux entrées.** `run` et `resume` partagent `walk` ;
   une traversée reprise n'est pas un cas particulier du moteur, c'est la même
   marche commencée ailleurs.
