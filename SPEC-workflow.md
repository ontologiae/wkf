# Moteur de workflow — spécification

## Objet

Un **graphe d'exécution défini en base**, dont les nœuds appellent des fonctions
enregistrées et dont certains décident où aller ensuite.

C'est la mécanique que Patagonia emploie pour servir un tour de conversation :
classer la demande, choisir un modèle, calculer un thème quand il en faut un,
rédiger, relire. Mais ce document ne parle de rien de tout cela. Il décrit le
moteur seul, parce que **le moteur a vocation à sortir du dépôt** : c'est une
bibliothèque publiable, et une bibliothèque qui connaîtrait l'astrologie, les
crédits ou Athéna ne serait pas publiable.

### La règle de séparation, et elle est stricte

> Ce document ne nomme **jamais** un thème, un crédit, un compte, un prompt
> d'astrologie, ni une table de Patagonia. S'il le fait, c'est une faute, et la
> phrase appartient à `SPEC-conversation.md`.

Le symétrique vaut : `SPEC-auth.md` ne parle ni de conversations ni de
workflows, et `SPEC-conversation.md` ne redécrit pas le moteur.

### Les trois documents

| document | ce qu'il porte |
| --- | --- |
| `SPEC-auth.md` | comptes, identités, sessions, fédération, courriel, RGPD, et le grand livre des crédits |
| `SPEC-conversation.md` | ce que Patagonia fait des conversations : services, prompts, phases, thème, tarif, profil, langues |
| **`SPEC-workflow.md`** | **ce document** : le moteur de graphe, ses nœuds, son registre de fonctions, son contrat |

---

## 1. Le périmètre — un graphe, pas un statechart

C'est la première décision, et c'est une décision de **ce qu'on ne fait pas**.

Un statechart — au sens de Harel, celui des machines à états des interfaces —
apporte la hiérarchie d'états, les régions parallèles, les états d'historique,
les transitions inter-niveaux. Chacun de ces traits résout un problème réel, et
chacun coûte : une sémantique d'exécution qui ne se lit plus, des cas limites
qui ne se testent plus, et un outillage qu'il faut écrire avant de s'en servir.

**On n'en veut pas.** Ce moteur exécute un **graphe orienté acyclique**, plat :

| on a | on n'a pas |
| --- | --- |
| des nœuds, et des arêtes entre eux | des états dans des états |
| un nœud qui décide de l'arête suivante | des régions parallèles |
| un nœud terminal qui arrête la traversée | des états d'historique |
| une traversée = un parcours, du début à un terminal | des transitions qui traversent des niveaux |

### Pourquoi acyclique, et ce que ça interdit

Une **traversée** est un parcours unique, de l'entrée à un terminal. Elle ne
boucle pas. Ce qui boucle, c'est l'**application** qui relance une traversée au
coup suivant — et ce cycle-là vit chez l'hôte, pas dans le graphe.

L'acyclicité n'est pas une préférence esthétique : c'est ce qui rend le **coût
maximal d'une traversée calculable avant de l'exécuter** (§6). Un graphe qui
boucle n'a pas de chemin le plus cher, et tout ce qui repose sur ce chiffre
s'effondre.

Deux filets, parce qu'une déclaration ne suffit pas :

- le graphe est **vérifié acyclique au chargement**, et un cycle est un refus
  qui **nomme les nœuds du cycle** — pas un booléen : « ce graphe a un cycle »
  n'aide personne à le corriger. Cf. §10.3, où l'on voit que cette exigence
  décide de l'outil employé ;
- une traversée porte de toute façon un **plafond de nœuds visités**, porté par
  la ligne du graphe. Le premier filet attrape la faute de saisie ; le second
  attrape ce que le premier a raté, et personne n'a jamais regretté une borne.

---

## 2. Un nœud, c'est un appel de fonction

### 2.1 Une seule nature, et non trois

La tentation était d'avoir trois natures de nœud — « appel de modèle »,
« calcul », « routage » — et de les traiter chacune dans le moteur. Elle est
écartée.

**Un nœud est un appel de fonction enregistrée, point.** Ce qui distingue un
nœud qui interroge un modèle de langage d'un nœud qui calcule quelque chose,
c'est la fonction, pas le moteur. Trois conséquences, et la troisième est la
raison principale :

1. le moteur n'a aucun code propre au modèle de langage — il n'en connaît
   même pas la notion ;
2. ajouter une nature de travail, c'est enregistrer une fonction, pas modifier
   le moteur ;
3. **changer de fournisseur de modèle est un changement chez l'hôte.** La
   fonction qui appelle un modèle est fournie par l'application ; qu'elle passe
   par un agrégateur ou par l'API directe d'un fournisseur ne regarde pas le
   graphe.

### 2.2 Le routage n'est pas une nature à part

Un nœud **route** quand sa sortie nomme le nœud suivant. C'est tout.

```
  sortie du nœud      ce que le moteur en fait
  ──────────────────  ────────────────────────────────────────────
  { "suivant": "n" }  on va au nœud « n », quelle que soit l'arête
  { "suivant": null } la traversée s'arrête ici, sans terminal
  { }                 on suit l'arête déclarée dans le graphe
```

Une fonction de décision et une fonction de calcul sont donc le même objet. Une
fonction qui calcule *puis* décide — « j'ai regardé ce qu'on me demande, va au
nœud de synastrie » — n'est pas un cas particulier : c'est une fonction dont la
sortie porte les deux.

### 2.3 La sortie est libre, sauf trois champs

```
  { "suivant": "<nom de nœud>" | null,     réservé — cf. 2.2
    "prix":    <entier>,                   réservé — cf. §6, un seul nœud le pose
    "echec":   "<phrase>",                 réservé — cf. §5
    ...tout le reste... }
```

Tout ce qui n'est pas ces trois champs est **libre, opaque au moteur, et
conservé**. C'est ce qui permet à l'hôte de mesurer une traversée sans que le
moteur ait eu à prévoir la mesure : une fonction rend sa confiance, son coût, ce
qu'elle a lu, et cela devient une requête sur du `jsonb` plutôt qu'une migration.

La sortie de chaque nœud visité est empilée dans la trace de la traversée, dans
l'ordre. Cette trace n'est pas qu'un journal pour l'hôte : les fonctions
suivantes de la même traversée la relisent aussi — cf. §3.3.

---

## 3. Le registre de fonctions

### 3.1 La base nomme, le code fait

Une ligne de graphe porte le **nom** d'une fonction. Le moteur la cherche dans
un registre que l'hôte a rempli au démarrage.

```ocaml
(** Le registre. Modulaire par construction : une fonction est un module qui
    satisfait {!FONCTION}, et l'enregistrement se fait une fois, au démarrage.

    C'est ce qui remplace un langage d'expressions en base (§10) : ce qui est
    stocké est un NOM et des DONNÉES, jamais du code. Un nom se vérifie au
    chargement du graphe ; une expression ne se vérifie qu'en s'exécutant, sur
    une traversée réelle, chez quelqu'un. *)
module type FONCTION = sig
  val nom : string

  type entree
  (** Le type de la configuration, {b engendré par atdgen}. Cf. §4 — c'est ce
      qui donne au JSON de la base une validation qu'un [jsonb] n'a pas. *)

  val lire_entree : string -> entree
  (** Le lecteur engendré. Il lève sur une entrée malformée, en nommant le
      champ fautif ; le moteur attrape et refuse le nœud en le disant. *)

  val executer :
    entree:entree -> contexte:Yojson.Safe.t -> trace:trace ->
    (Yojson.Safe.t, string) result Lwt.t
  (** [trace] : ce que les nœuds déjà visités de cette traversée ont rendu,
      jamais le nœud courant lui-même. Cf. §3.3. *)
end

val enregistrer : (module FONCTION) -> unit
val connue : string -> bool
```

### 3.2 Ce que le contexte porte, et ce qu'il ne porte pas

Le `contexte` est monté par **l'hôte** et passé tel quel. Le moteur ne le lit
pas, ne le complète pas, ne le valide pas : il le transporte.

C'est délibéré, et c'est ce qui garde le moteur générique. Un contexte typé par
le moteur imposerait au moteur de connaître ce que l'application met dedans —
c'est-à-dire, ici, des conversations et des soldes. Le prix en est que le moteur
ne peut rien garantir sur le contexte ; la garantie, c'est chaque fonction qui
la pose, sur la part qui la concerne.

### 3.3 Ce qu'une fonction voit de la traversée en cours : la trace

Le `contexte` (§3.2) est fixé une fois, par l'hôte, avant que la traversée ne
commence, et il ne change pas d'un nœud à l'autre. Une fonction qui décide
*et calcule quelque chose* — pas seulement « où aller », mais une valeur que la
suite doit employer — n'a donc aucun moyen de la faire passer par ce canal : il
faudrait la connaître avant que la traversée existe.

La **trace** (§2.3) comble ce manque, à droit égal avec le contexte mais pour
une raison inverse : le contexte est ce que l'hôte savait avant, la trace est
ce que la traversée elle-même a déjà produit. Chaque fonction la reçoit, dans
l'ordre où les nœuds ont été visités — jamais le nœud courant, puisqu'il n'a
pas encore rendu —, et peut y chercher, par nom, ce qu'un nœud antérieur a
rendu.

C'est délibérément une lecture typée en OCaml, et non un petit langage de
gabarit (`{{nœud.sortie.champ}}`, à la manière d'Argo Workflows) : chercher une
valeur dans la trace dans le code d'une fonction se vérifie par le compilateur,
comme n'importe quel accès à une structure de données ; un gabarit en chaîne de
caractères, stocké en base, ne se vérifierait qu'à l'exécution — exactement le
langage d'expressions que le §11 écarte déjà, revenu par une autre porte.

La trace est donc double : rendue à l'hôte à la fin de la traversée (§2.3,
§7), et relue par les fonctions en cours de route.

### 3.4 Une fonction inconnue est une faute d'exploitation

Elle ne se traite **pas** comme une panne d'exécution. Un graphe qui nomme une
fonction absente du registre veut dire que **ce qui est écrit n'est pas ce qui
s'exécute**, et c'est le genre de chose qui doit crier :

- au **chargement** du graphe, c'est un refus qui nomme le nœud et la fonction ;
- en **exécution** — un graphe modifié pendant que le service tourne —, c'est
  l'échec du nœud au sens du §5, en nommant le nom.

Jamais un silence, jamais un repli implicite.

---

## 4. Le contrat JSON, typé par l'ATD

Le JSON en base donne la souplesse : une fonction nouvelle qui veut un paramètre
nouveau n'impose de migration à personne. Il ne donne aucune validation — un
`jsonb` accepte n'importe quoi.

**Rien n'oblige à s'en contenter.** Chaque fonction déclare son entrée dans
`.atd`, atdgen en engendre le lecteur, et le lecteur refuse une entrée
malformée en nommant le champ :

```
  lib/workflow.atd
    type entree_seuil = { seuil : int; sinon : string }
    type entree_appel_modele = { modele : string; prompt : string; ?plafond : int option }
```

Ce qu'on obtient : la souplesse du `jsonb` côté schéma, et un refus qui parle
côté lecture. Ce qu'on paie : une fonction n'est plus de la pure donnée — en
ajouter une demande un type ATD, donc une compilation. C'est le bon prix, parce
qu'**une fonction est du code de toute façon** ; seule sa configuration est de
la donnée.

**La validation a lieu au chargement du graphe, pas à l'exécution.** Une entrée
fautive doit se voir quand on pose le graphe, pas au milieu d'une traversée que
quelqu'un attend.

---

## 5. L'échec, déclaré nœud par nœud

Il n'y a **pas** de politique d'échec générale. La première version de ce
document en posait une — « un nœud en panne ne bloque jamais » — et elle est
fausse dans les deux sens : un nœud d'agrément peut tomber sans conséquence, un
nœud qui produit ce que la traversée doit rendre ne le peut pas.

La politique est donc **une colonne**, portée par le nœud :

| `sur_echec` | ce qui se passe |
| --- | --- |
| `arreter` | la traversée échoue. C'est le défaut, parce que c'est le choix sûr |
| `poursuivre` | le nœud est réputé n'avoir rien rendu (`{}`), on suit l'arête déclarée |
| `devier` | on va au nœud nommé par `echec_vers` — la branche de repli |

Le défaut est `arreter`, et ce n'est pas un détail. Un moteur qui poursuit par
défaut transforme chaque panne en dégradation silencieuse ; il faut avoir à
écrire `poursuivre` pour l'obtenir, et l'écrire est un acte.

**Un échec se journalise toujours**, quelle que soit la politique. `poursuivre`
veut dire « la traversée continue », jamais « on n'en parle pas ».

---

## 6. Le prix d'une traversée

### 6.1 Un seul nœud le pose, et c'est celui d'entrée

Le prix d'une traversée est **fixé une fois, par le premier nœud qui en pose
un** — en pratique le nœud de routage d'entrée — et il ne bouge plus.

L'alternative serait de l'accumuler nœud par nœud. Elle est écartée : un prix
qui s'accumule n'est connu qu'à la fin, or l'intérêt du prix est d'être connu
**avant**, pour que l'hôte puisse le réserver et l'annoncer. On ne peut annoncer
que ce qu'on a décidé, jamais ce qu'on est en train de dépenser.

Une seule souplesse : un nœud ultérieur peut **baisser** le prix, jamais le
relever. Le sens est net — on peut rendre moins cher que promis, on ne peut pas
rendre plus cher.

Le moteur ne sait pas ce qu'est ce nombre. C'est un entier qu'il transporte et
qu'il rend à l'hôte.

### 6.2 La contrainte que cela impose au concepteur du graphe

Elle est simple à énoncer et elle tient tout :

> **Le chemin le plus cher d'un graphe doit coûter moins que le prix que son
> nœud d'entrée annonce.**

Faute de quoi il existe un parcours qui se vend à perte, et il finira par
arriver — ce n'est pas une hypothèse, c'est un chemin qui existe.

C'est pour cela que le graphe est acyclique : sur un DAG, le chemin le plus cher
se calcule. Chaque nœud déclare un **coût maximal** — ce que son travail peut
coûter au pire, dans l'unité de l'hôte —, et le moteur offre une vérification :

```ocaml
val cout_maximal : graphe -> nom_de_noeud -> int
(** Le coût du chemin le plus cher depuis ce nœud. Calculé sur le DAG, une fois
    au chargement. À comparer au prix que le nœud d'entrée pose : si le coût
    dépasse le prix, le graphe se vend à perte sur au moins un parcours, et
    c'est un AVERTISSEMENT nommé, pas un refus.

    Un avertissement et non un refus, parce que le moteur ne connaît ni les
    unités ni la marge de l'hôte : il ne peut pas savoir qu'un dépassement est
    délibéré. Il peut en revanche refuser de le taire. *)
```

C'est une vérification qu'on ne peut pas faire sans acyclicité, et c'est la
raison pour laquelle le §1 en fait une règle plutôt qu'une préférence.

---

## 7. Une traversée est une unité, et voici ce que ça ne veut pas dire

Le mot juste est **transaction**, et il faut aussitôt dire ce qu'elle ne couvre
pas, parce que la moitié fausse du mot est celle qui coûte cher.

### Ce qui est transactionnel

- **Les écritures de l'hôte** : le moteur n'écrit rien lui-même. Il rend une
  trace, et l'hôte la commet — ou non — dans **sa** transaction. Une traversée
  qui échoue ne laisse donc aucun état partiel, si l'hôte fait son travail.
- **Le prix** : une traversée qui n'aboutit pas ne se facture pas. C'est une
  garantie que le moteur rend possible en distinguant nettement « traversée
  réussie » de « traversée interrompue ».

### Ce qui ne l'est pas, et ne le sera jamais

**Les effets de bord déjà partis.** Un nœud qui a interrogé un service extérieur
a consommé quelque chose chez ce service, et aucune annulation ne le rend. Une
traversée avortée après trois nœuds coûteux a **coûté** trois nœuds coûteux.

Il n'y a pas de compensation automatique, et il n'y en aura pas : un mécanisme
d'annulation par nœud — un `compensate` à la Saga — demande que chaque fonction
sache défaire ce qu'elle a fait, ce qui est faux pour la plupart d'entre elles.
Mieux vaut le dire que le simuler.

**La conséquence est économique et appartient à l'hôte** : le coût d'une
traversée avortée est à sa charge. C'est chiffrable, ça se mesure, et c'est une
ligne de perte assumée — pas un cas d'erreur.

### Ce que le moteur rend

```ocaml
type issue =
  | Aboutie of { trace : trace; prix : int option }
  | Interrompue of { trace : trace; noeud : string; motif : string }
  (** [trace] est rendue dans les DEUX cas, et c'est le point : une traversée
      interrompue est précisément celle qu'on voudra relire. La jeter pour
      « faire propre » effacerait la seule chose qui dit pourquoi. *)
```

---

## 8. L'état d'une traversée, et sa reprise

Le §7 dit ce qu'une traversée avortée coûte, et s'arrête là : les effets déjà
partis ne reviennent pas, la perte est à la charge de l'hôte, point. Il
manquait la suite, et elle est simple à énoncer :

> Si on ne peut pas récupérer ce qui est parti, on peut au moins **ne pas le
> refaire**.

D'où la règle : **l'état courant d'une traversée s'écrit, à chaque frontière de
nœud.** Un service coupé au milieu d'une traversée laisse sinon une ligne qui
dit qu'on a commencé et rien qui dise jusqu'où — c'est-à-dire qu'il faut tout
repayer, y compris les nœuds qui avaient abouti.

### 8.1 Le moteur n'écrit toujours rien

Cette section n'annule pas le §9 : le moteur ne connaît pas votre base et ne
l'apprendra pas ici. Il **construit** un état — une valeur, sérialisable — et
le passe à une fonction de **point de reprise** que l'hôte lui a donnée.
L'hôte l'écrit où il garde ce genre de chose.

La conséquence est que la reprise ne coûte aucune dépendance au paquet : ni
pilote de base, ni schéma obligatoire. Le `.sql` fourni (§10) propose des
tables pour qui veut PostgreSQL ; ce n'est qu'une proposition.

### 8.2 Deux frontières par nœud, et pourquoi pas une

Un point de reprise s'écrit **avant** qu'un nœud travaille, et **après** qu'il
a rendu, une fois le suivant connu :

```
  statut      ce que le service qui redémarre apprend
  ──────────  ─────────────────────────────────────────────────────────
  prêt n      rien n'était en vol ; n est à faire, et rien n'est perdu
  en vol n    n travaillait à la coupure, et nul ne sait jusqu'où
```

C'est deux écritures par nœud, et les réunir en une seule perdrait exactement
la distinction qui compte. N'écrire qu'**avant** : un nœud qui avait abouti est
retrouvé « en vol », et son travail est rejeté pour rien. N'écrire qu'**après**
: un nœud coupé en plein travail est retrouvé « prêt », et il est refait — ce
qui est précisément ce qu'on voulait éviter.

Qui trouve deux écritures trop cher les regroupe dans sa propre fonction : il
obtiendra le second comportement à chaque coupure, et ce sera son choix, écrit
quelque part.

### 8.3 Le nœud en vol, et la seule chose que le moteur ne peut pas décider

Un nœud retrouvé « en vol » a peut-être déjà appelé son service extérieur,
peut-être pas. **Rien, dans le moteur, ne peut le savoir** : c'est la même
ignorance qu'au §7, vue de l'autre bout.

La décision est donc une colonne, comme la politique d'échec, et pour la même
raison :

| `on_resume` | ce qui se passe à la reprise |
| --- | --- |
| `fail` | le nœud est réputé avoir échoué, et sa propre politique `on_failure` prend le relais. C'est le défaut |
| `rerun` | le nœud est refait, parce que son travail est idempotent |

Le défaut est `fail`, et c'est le même raisonnement qu'au §5 : un moteur qui
relance par défaut fait repartir des effets de bord sans que personne l'ait
demandé, et une facture double est un dégât silencieux. Il faut avoir à écrire
`rerun`, et l'écrire est une affirmation : *ce travail-là peut être refait*.

Noter ce que `fail` compose : un nœud en vol dont `on_failure` vaut `devier`
part sur sa branche de repli, ce qui est souvent exactement ce qu'on veut d'une
reprise. Les deux colonnes ne se recouvrent pas, elles se complètent.

### 8.4 Un point de reprise qui n'aboutit pas arrête la traversée

Une écriture refusée — base indisponible, disque plein — **interrompt**. Une
traversée qui continuerait dépenserait de l'argent que plus rien ne pourrait
rattacher à quoi que ce soit : c'est le cas qu'on voulait fermer, pas un cas
d'erreur secondaire.

Cela vaut **aussi pour la dernière écriture**, celle qui dit que la traversée a
abouti. Le travail est fait, et rien ne peut l'enregistrer : la rendre comme
aboutie ferait facturer à l'hôte une traversée que ses propres livres ignorent.
Elle est donc rendue interrompue — donc non facturée — et la trace revient
entière, de sorte que rien de ce qui a été appris n'est perdu.

### 8.5 Ce que l'état porte

| champ | pourquoi |
| --- | --- |
| le graphe | vérifié à la reprise : un état repris contre un autre graphe parcourt la carte d'ailleurs |
| le statut | `prêt`, `en vol`, `abouti`, `interrompu` — cf. §8.2 |
| le nœud | en vol, à faire, ou celui où l'on s'est arrêté |
| la trace | ce qui est déjà fait, et qui ne sera pas refait |
| le prix | fixé une fois (§6.1), il traverse la coupure ; sinon le nœud d'entrée le reposerait |
| les nœuds visités | pour que le plafond du §1 veuille dire la même chose des deux côtés de la coupure |
| le contexte | pour qu'un service qui redémarre ait de quoi continuer sans rien reconstituer |
| le motif | pourquoi elle s'est interrompue |

Le contexte est le seul champ qui demande un arbitrage à l'hôte : le stocker,
c'est écrire dans une table ce que l'application a mis dedans. Le moteur le
met dans l'état parce que sans lui la reprise exige de tout reconstituer ;
l'hôte le retire avant d'écrire s'il ne veut pas le garder, et le redonne
lui-même au moment de reprendre.

### 8.6 Ce qui reste à l'hôte : nommer la traversée

Le moteur ne donne pas d'identité aux traversées. Ce n'est pas un oubli : une
identité engagerait une forme (un entier ? un UUID ? une clé composite ?) que
la base de l'hôte a déjà décidée. La fonction de point de reprise est une
fermeture, elle capture l'identifiant que l'hôte lui a donné, et le moteur n'a
rien à en savoir.

Les tables qui vont avec, pour qui prend le `.sql` fourni :

```sql
-- L'état courant, une ligne par traversée, réécrite à chaque frontière.
create table wkf_traversal (
  id bigint generated always as identity primary key,
  graph_id int not null references wkf_graph(id),
  status wkf_traversal_status not null default 'ready',
  node text, price int, visited int not null default 0,
  context jsonb not null default 'null'::jsonb, reason text,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- La trace, une ligne par nœud visité, ajoutée et jamais réécrite. Elle
-- pourrait être une colonne jsonb de la ligne ci-dessus — elle en est une dans
-- l'état que le moteur rend. Ici ce sont des lignes, parce que la sortie d'une
-- fonction est libre et conservée (§2.3), et que cela ne vaut quelque chose
-- que si elle s'interroge.
create table wkf_traversal_step (
  traversal_id bigint not null references wkf_traversal(id) on delete cascade,
  seq int not null, node text not null, handler text not null,
  output jsonb not null default '{}'::jsonb, failure text,
  at timestamptz not null default now(),
  primary key (traversal_id, seq)
);
```

Et ce qu'un service lit en redémarrant : une vue des traversées que ses propres
tables tiennent encore pour vivantes. Celles en `en vol` ont été coupées en
plein nœud ; ce qu'il advient de ce nœud est écrit dans le graphe (§8.3), et le
moteur l'applique.

---

## 9. Ce que l'hôte doit fournir

Le moteur ne se suffit pas à lui-même, et la liste de ce qui lui manque est
courte — c'est le signe qu'on a coupé au bon endroit.

| l'hôte fournit | pourquoi le moteur ne peut pas |
| --- | --- |
| **le stockage du graphe** | le moteur ne connaît pas votre base. Il consomme un graphe déjà lu |
| **le point de reprise** | le moteur construit l'état d'une traversée (§8) ; l'écrire, c'est encore la base de l'hôte |
| **l'identité d'une traversée** | entier, UUID, clé composite : la base de l'hôte l'a déjà décidé (§8.6) |
| **les fonctions** | c'est tout le travail utile : appeler un modèle, calculer, décider |
| **le contexte** | ce qu'une traversée a besoin de savoir appartient à l'application |
| **la facturation** | le moteur transporte un entier appelé « prix » et n'en sait rien de plus |
| **le journal** | le moteur émet des événements ; où ils vont ne le regarde pas |
| **la transaction** | c'est la base de l'hôte, c'est sa transaction |

---

## 10. Le schéma

Trois tables pour le graphe — et deux de plus pour l'état des traversées, au
§8.6 —, et des **enums** plutôt que du texte : un domaine fermé se code
dans le type. La contrepartie est assumée — une valeur nouvelle devient un
`ALTER TYPE … ADD VALUE`, donc une migration, là où une table de référence se
serait contentée d'un `INSERT`.

### 10.1 Un graphe est une ligne, pas une chaîne répétée

La première version de ce schéma portait le graphe comme une **colonne de
texte**, recopiée sur chaque nœud et chaque arête. C'était du relationnel en
apparence seulement : aucune table ne déclarait les graphes, donc rien
n'empêchait une faute de frappe de créer un graphe fantôme d'un seul nœud, et
rien n'avait d'endroit où vivre au niveau du graphe — son nœud de départ, son
plafond, son état actif.

Un graphe est donc **une ligne, avec un identifiant**, et tout le reste le
référence.

```sql
-- Comment un nœud réagit à son propre échec (§5).
create type wf_sur_echec as enum ('arreter', 'poursuivre', 'devier');

-- Un graphe : ce qui porte les attributs de l'ensemble.
create table if not exists wf_graphe (
  id      int generated always as identity primary key,
  nom     text not null unique,        -- 'tour_de_conversation'
  -- Le filet du §1 : au-delà, la traversée s'arrête quoi qu'il arrive. Il
  -- attrape ce que la vérification d'acyclicité aurait raté.
  plafond_noeuds int not null default 50,
  actif   boolean not null default true,
  cree_le timestamptz not null default now()
);

-- Un nœud : un nom de fonction, sa configuration, sa politique d'échec.
create table if not exists wf_noeud (
  id        int generated always as identity primary key,
  graphe_id int not null references wf_graphe(id) on delete cascade,
  nom       text not null,             -- unique DANS son graphe, pas au-delà
  -- Le nom d'une fonction du registre (§3). Vérifié au chargement.
  fonction  text not null,
  -- La configuration, validée par le type ATD de la fonction (§4).
  entree    jsonb not null default '{}'::jsonb,
  -- Ce que ce nœud peut coûter AU PIRE, dans l'unité de l'hôte. Sert au calcul
  -- du chemin le plus cher (§6.2) ; le moteur ne l'interprète pas autrement.
  cout_max  int not null default 0,
  sur_echec wf_sur_echec not null default 'arreter',
  echec_vers int,
  -- Par où la traversée commence. Un seul par graphe, et l'index partiel plus
  -- bas l'impose : deux départs se départageraient par l'ordre du plan
  -- d'exécution, c'est-à-dire par rien.
  depart    boolean not null default false,
  terminal  boolean not null default false,
  unique (graphe_id, nom),
  -- Cette clé-là n'est pas décorative : elle rend possible la clé étrangère
  -- composite ci-dessous, qui est ce qui EMPÊCHE une référence de sortir du
  -- graphe. Sans elle, un « echec_vers » pourrait désigner un nœud d'un autre
  -- graphe, et la traversée changerait de graphe en cours de route.
  unique (graphe_id, id),
  foreign key (graphe_id, echec_vers) references wf_noeud (graphe_id, id),
  -- « devier » sans destination est une ligne qui ment : refusée à l'écriture,
  -- plutôt que découverte au moment où le nœud échoue.
  constraint devier_a_une_destination
    check (sur_echec <> 'devier' or echec_vers is not null)
);

create unique index if not exists wf_noeud_depart_unique
  on wf_noeud (graphe_id) where depart;

-- Une arête : où l'on va quand le nœud n'a pas nommé son suivant lui-même.
--
-- Une seule arête sortante par nœud, et c'est voulu : le choix appartient aux
-- fonctions (§2.2), pas à une table de conditions. L'arête est le chemin par
-- défaut, celui qu'on suit quand personne n'a décidé autrement — d'où la clé
-- primaire sur [depuis] seul.
--
-- [graphe_id] y est recopié pour la même raison que ci-dessus : c'est ce qui
-- permet aux deux clés étrangères composites d'exiger que les deux bouts
-- appartiennent au MÊME graphe. Une arête entre deux graphes n'est pas une
-- erreur qu'on veut détecter en OCaml, c'est une ligne qu'on veut voir refusée.
create table if not exists wf_arete (
  graphe_id int not null,
  depuis    int primary key,
  vers      int not null,
  foreign key (graphe_id, depuis) references wf_noeud (graphe_id, id) on delete cascade,
  foreign key (graphe_id, vers)   references wf_noeud (graphe_id, id) on delete cascade
);
```

### 10.2 Ce que le schéma ne peut pas dire

**L'acyclicité n'est pas exprimable en contrainte SQL.** Elle se vérifie au
chargement, et c'est là que le refus nomme les nœuds du cycle (§10.3).

**L'accessibilité non plus** : rien n'empêche un nœud orphelin, qu'aucune arête
n'atteint et qui n'est pas le départ. Ce n'est pas une faute — on écrit un
graphe par morceaux — mais c'est un **avertissement** que le chargement doit
donner, parce qu'un nœud inaccessible est presque toujours une arête oubliée.

### 10.3 La théorie des graphes ne se réécrit pas — `ocamlgraph`

Le dépôt a pour règle de ne pas réécrire ce qu'une bibliothèque fait déjà. Elle
vaut ici, et `ocamlgraph` (2.2.0) rend trois choses, dont la troisième n'était
pas demandée :

| ce qu'il faut | ce que `ocamlgraph` donne |
| --- | --- |
| détecter un cycle | `Traverse.Dfs.has_cycle`, linéaire en temps et en espace |
| **nommer** les nœuds du cycle | `Components.Make.scc` — une composante fortement connexe de plus d'un sommet **est** le cycle, et elle en donne la liste. `has_cycle` seul ne rend qu'un booléen, ce qui ne suffit pas au refus que le §1 promet |
| le chemin le plus cher (§6.2) | `Topological.Make.fold` donne l'ordre topologique ; le reste est une dizaine de lignes de programmation dynamique. Il n'existe pas de « plus long chemin pondéré » tout fait — et il n'en faut pas, le problème n'étant facile que sur un DAG |
| *(en prime)* **dessiner le graphe** | `Graphviz.Dot` émet du DOT depuis le graphe chargé. Un graphe écrit en base et jamais vu est un graphe dont personne ne vérifie la forme ; un `.svg` engendré à la demande le rend relisible |

**Le poids de la dépendance a été vérifié** avant de la proposer, parce qu'une
bibliothèque publiée hérite des dépendances de ses dépendances :
`ocamlgraph` ne demande que `ocaml (>= 4.08)` et `dune` — `graphics` n'est tiré
qu'en `with-test`. C'est à peu près aussi léger qu'un paquet puisse l'être, et
cela ne ferme aucune porte à qui installera ce moteur.

**Ce qu'on écrit quand même nous-mêmes** : la lecture du schéma vers le graphe,
et la programmation dynamique du chemin le plus cher. Le premier est propre à
nos tables, le second tient en dix lignes une fois l'ordre topologique obtenu.

## 11. Ce qui n'est pas retenu

**Un langage d'expressions en base.** `solde > 3 and tours < 10` dans une
colonne : une expression par nœud, évaluée au vol. Écarté, parce que c'est du
code exécutable dans une table qu'on modifie par `UPDATE` sans relancer — donc
des erreurs de syntaxe qui n'apparaissent qu'à l'exécution, sur une traversée
réelle. Le registre de fonctions donne la même souplesse : ce qui est en base
est un nom et des données.

**Un statechart.** Cf. §1. La hiérarchie, le parallélisme et les états
d'historique résolvent des problèmes qu'on n'a pas, au prix d'une sémantique
qu'on ne saurait pas tester.

**Un contexte typé par le moteur.** Il obligerait le moteur à connaître ce que
l'application met dedans. Cf. §3.2.

**Une compensation automatique par nœud.** Cf. §7 : elle suppose que chaque
fonction sache défaire ce qu'elle a fait, ce qui est faux.

**Un prix qui s'accumule.** Cf. §6.1 : il n'est connu qu'à la fin, donc
inannonçable.

**Plusieurs arêtes sortantes avec conditions.** Ce serait le langage
d'expressions par une autre porte. Une arête par nœud, et le choix aux
fonctions.

**Un paramétrage par gabarit** (`{{nœud.sortie.champ}}`, à la manière d'Argo
Workflows). Cf. §3.3 : une fonction qui veut ce qu'un nœud antérieur a rendu le
cherche dans la trace, en OCaml, vérifié par le compilateur. Un gabarit en
chaîne stocké en base ne serait, encore, qu'un langage d'expressions revenu par
une autre porte.

**Le nom du graphe comme clé étrangère.** C'était la première version du §10 :
une colonne de texte recopiée sur chaque nœud et chaque arête, sans table pour
déclarer les graphes. Écarté — une faute de frappe y créait un graphe fantôme
sans que rien ne s'y oppose, et les attributs de l'ensemble (nœud de départ,
plafond, état actif) n'avaient nulle part où vivre.

**Écrire nous-mêmes la détection de cycle et l'ordre topologique.** Une
quinzaine de lignes, certes. Mais `ocamlgraph` les a déjà, testées, et ne pèse
que `ocaml` et `dune` (§10.3) — et la règle du dépôt est de ne pas réécrire ce
qu'une bibliothèque fait déjà. Ce qui reste à nous : la lecture du schéma, et la
programmation dynamique du chemin le plus cher, qui n'existe nulle part toute
faite parce qu'elle n'est facile que sur un DAG.

---

## 12. Un dépôt à part

Ce n'est pas « on extraira peut-être un jour ». C'est arrêté : **le moteur aura
son dépôt, son git et son paquet opam.** Ce document décrit donc un logiciel qui
n'habitera pas ici, et qui vit dans `lib/workflow*.ml` en attendant.

### 12.1 Ce que « dépôt à part » impose dès maintenant

- **aucune dépendance à Dream**, ni à `caqti`, ni aux tables de Patagonia. Le
  moteur consomme un graphe **déjà lu** ; c'est l'hôte qui sait le lire ;
- **aucun nom du domaine** dans le code ni dans les commentaires. Un `grep` sur
  `thème`, `crédit`, `astro`, `Athéna` doit sortir vide — c'est une assertion de
  lot, pas une intention ;
- **les dépendances se comptent.** Elles deviennent celles de qui installera le
  paquet. À ce jour : `lwt` (une fonction de nœud est asynchrone par nature, un
  moteur synchrone ne servirait à rien), `yojson`, `atdgen-runtime`, et
  `ocamlgraph` — dont le §10.3 a vérifié qu'il ne tire rien lui-même ;
- **le schéma part avec**, dans un `.sql` fourni par le paquet et appliqué par
  l'hôte ;
- **un `dune-project` à lui**, avec son `depends` complet. La règle du dépôt —
  toute dépendance se déclare aux DEUX endroits — n'est pas une formalité pour
  un paquet publié : ce qui manque au `depends` ne se voit pas sur la machine de
  l'auteur, dont le switch a tout. Il se voit chez le premier qui l'installe.

Tant que l'extraction n'est pas faite, le moteur se comporte **comme s'il était
déjà dehors**. C'est la seule façon de ne pas découvrir au moment de le sortir
qu'il a poussé des racines.

### 12.2 Il sera publié, donc il sera en anglais

Ce dépôt écrit tout en français — identifiants, commentaires, messages,
documentation. C'est une règle de **ce** dépôt, et elle a sa raison : ses deux
auteurs pensent en français, et une spécification qu'on lit dans sa langue est
une spécification qu'on relit.

Un paquet opam publié n'a pas cette audience. Ses lecteurs sont ceux qui
l'installeront, et ils ne sont pas francophones. **Le moteur sera donc en
anglais**, documentation et identifiants.

#### Ce que cela coûte, et quand le payer

La question n'est pas *si* mais *quand*, et les deux moitiés n'ont pas la même
réponse.

**Le document peut attendre.** Il bouge encore — il vient d'être annoté deux
fois. Traduire un texte en mouvement, c'est le traduire deux fois, et ces
485 lignes sont surtout des **arguments** : « pourquoi acyclique », « ce que
transaction ne couvre pas ». C'est précisément le genre de prose dont une
traduction tardive perd la nuance, mais c'est aussi le genre qu'on ne veut pas
figer avant que la décision soit stable. **On traduit à l'extraction**, en
acceptant que ce soit une réécriture et non une conversion.

**Les identifiants, non.** Ils doivent être décidés **avant** que le lot 3
n'écrive une ligne. Un moteur écrit en français — `FONCTION`, `enregistrer`,
`traversee`, `wf_noeud`, `sur_echec` — puis renommé au moment de la publication,
c'est un renommage qui traverse le code, le schéma, les migrations, les tests et
tous les commentaires qui nomment une valeur. Ce n'est pas un `sed` : un
commentaire qui explique `sur_echec` ne devient pas correct parce qu'on a
renommé la colonne.

**Recommandation** : fixer maintenant le vocabulaire des deux côtés, et écrire
le code directement en anglais. Le glossaire coûte une demi-heure et se
vérifie ; le renommage coûte un lot et ne se vérifie pas.

| français, dans ce document | anglais, dans le code |
| --- | --- |
| graphe | `graph` |
| nœud | `node` |
| arête | `edge` |
| traversée | `traversal` |
| fonction (de nœud) | `handler` |
| registre | `registry` |
| entrée (configuration) | `config` |
| contexte | `context` |
| sortie / décision | `outcome` |
| suivant | `next` |
| trace | `trail` |
| politique d'échec | `on_failure` |
| dévier / poursuivre / arrêter | `divert` / `continue` / `stop` |
| coût maximal | `max_cost` |
| prix | `price` |
| plafond de nœuds | `node_budget` |
| état (d'une traversée) | `state` |
| point de reprise | `checkpoint` |
| reprise / reprendre | `resume` |
| en vol | `in flight` |
| politique de reprise | `on_resume` |
| refaire / réputé échoué | `rerun` / `fail` |

**C'est le seul point de ce document qui demande un arbitrage avant d'écrire du
code.** Le reste peut se corriger en chemin.

## 13. Ce que ce document décide, en une page

1. Le moteur exécute un **graphe orienté acyclique**, plat. **Pas un
   statechart** : ni hiérarchie, ni parallélisme, ni état d'historique.
2. L'acyclicité est **vérifiée au chargement**, et doublée d'un plafond de nœuds
   visités par traversée.
3. **Un nœud est un appel de fonction enregistrée**, et rien d'autre. Il n'y a
   pas de nature « appel de modèle » dans le moteur — le modèle est une fonction
   de l'hôte, ce qui rend le changement de fournisseur indolore.
4. **Le routage n'est pas une nature à part** : un nœud route quand sa sortie
   porte `suivant`.
5. La sortie d'un nœud est **libre**, hors trois champs réservés — `suivant`,
   `prix`, `echec` — et elle est **conservée** dans la trace.
6. **La trace est aussi relue** : chaque fonction reçoit, en plus du contexte,
   ce que les nœuds antérieurs de la traversée ont rendu, et peut y chercher
   une valeur par nom. C'est le canal qui manquait au contexte, fixé trop tôt
   pour porter le résultat d'un nœud qui n'a pas encore couru.
7. Le registre associe un **nom** à un module `FONCTION`. Une fonction inconnue
   est une **faute d'exploitation** qui crie, jamais un repli silencieux.
8. Chaque fonction **déclare son entrée en ATD** : la souplesse du `jsonb` en
   base, un refus qui nomme le champ à la lecture, et la lecture a lieu **au
   chargement**.
9. La politique d'échec est **par nœud**, déclarée : `arreter` (défaut),
   `poursuivre`, `devier`. Un échec se journalise toujours.
10. Le **prix est fixé par le nœud d'entrée** et ne peut que baisser ensuite.
   Jamais accumulé, parce qu'un prix accumulé n'est pas annonçable.
11. Le **chemin le plus cher doit coûter moins que le prix annoncé**. Le moteur
    le calcule sur le DAG et **avertit** — il ne refuse pas, parce qu'il ne
    connaît pas la marge de l'hôte.
12. Une traversée est une **transaction pour l'état et pour le prix**, jamais
    pour les effets de bord déjà partis. Le coût d'une traversée avortée est une
    **perte assumée** de l'hôte.
13. La trace est rendue **dans les deux cas**, abouti ou interrompu.
14. **L'état courant d'une traversée s'écrit à chaque frontière de nœud**, et
    le moteur n'écrit toujours rien lui-même : il construit un état et le passe
    au point de reprise que l'hôte lui donne. Deux écritures par nœud — avant
    et après —, parce qu'une seule ne distingue plus « coupé en plein travail »
    de « pas encore commencé ».
15. **Le nœud en vol à la coupure est réputé échoué**, et sa politique
    `on_failure` prend le relais. Le refaire se déclare, nœud par nœud
    (`on_resume: rerun`), parce que le moteur ne peut pas savoir si son travail
    est déjà parti — et qu'une facture double est un dégât silencieux.
16. **Un point de reprise refusé interrompt la traversée**, la dernière
    écriture comprise : une traversée qu'on ne peut pas enregistrer ne se
    facture pas, et sa trace revient tout de même.
17. Les domaines fermés sont des **enums PostgreSQL**, et la migration DDL qui
    va avec est assumée.
18. **Un graphe est une ligne avec un identifiant**, pas un nom recopié sur
    chaque enregistrement. Les références internes passent par des clés
    étrangères **composites**, qui empêchent une arête ou une déviation de
    sortir de son graphe — refusé à l'écriture, pas détecté en OCaml.
19. **`ocamlgraph` fait la théorie des graphes** : cycle, composantes fortement
    connexes (pour *nommer* le cycle), ordre topologique, et le DOT qui permet
    de dessiner un graphe écrit en base. Il ne pèse que `ocaml` et `dune`, ce
    qui compte pour un paquet publié.
20. Le moteur aura **son dépôt, son git et son paquet opam**. Il se comporte
    **dès maintenant** comme s'il était déjà dehors — vérifié par assertion, pas
    par intention.
21. Il sera **publié, donc en anglais**. Le document se traduit à l'extraction ;
    **les identifiants se décident avant d'écrire du code**, parce qu'un
    renommage tardif traverse le schéma, les migrations, les tests et tous les
    commentaires qui nomment une valeur. Glossaire proposé au §12.2 — c'est le
    seul point qui demande un arbitrage avant le lot 3.

---

Les relectures annotées et ce qu'elles ont changé : [`annotations-20260920.md`](annotations-20260920.md).
