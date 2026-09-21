#!/bin/bash
# Exécute une commande en la journalisant intégralement (commande, durée, code
# de retour, sortie complète — stdout et stderr mêlés, jamais tronquée).
#   ./run.sh dune build
# Le sha1 des fichiers de script exécutés est journalisé quand la commande en
# nomme un (premier argument se terminant par .sh ou .sql).
D="$(dirname "$(readlink -f "$0")")"
J="$D/journal.sh"

CMD="$*"
for a in "$@"; do
  case "$a" in
    *.sh|*.sql|*.ml|*.mli|*.atd)
      [ -f "$a" ] && CMD="$CMD [sha1 $a=$(sha1sum "$a" | cut -c1-12)]" ;;
  esac
done
"$J" ACTION "$CMD"

T0=$(date +%s.%N)
OUT=$("$@" 2>&1); RC=$?
T1=$(date +%s.%N)
# Durée sans printf flottant : LC_ALL=fr_FR.UTF-8 est positionné sur cette
# machine et écrase LC_NUMERIC, donc printf '%.1f' refuserait le point décimal
# et la durée serait perdue en silence. bc arrondit, %s imprime.
DUR=$(printf '%s' "$(echo "scale=2; ($T1 - $T0)/1" | bc)")

if [ $RC -ne 0 ]; then
  "$J" ERROR "echec rc=$RC en ${DUR}s : $CMD"
else
  "$J" RESULT "ok rc=0 en ${DUR}s : $CMD"
fi
if [ -n "$OUT" ]; then
  # Sortie intégrale, une entrée par ligne pour rester grep-able.
  printf '%s\n' "$OUT" | while IFS= read -r l; do "$J" RESULT "| $l"; done
fi
printf '%s\n' "$OUT"
exit $RC
