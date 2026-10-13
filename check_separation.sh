#!/bin/bash
# The separation rule, asserted rather than intended.
#
# This library is meant to be published, and a library that knew about the
# application it was extracted from would not be. So: no name from that
# application's domain, in the code or in the comments. The specification asks
# for this to be a check, not an intention -- so it runs with the tests.
#
# SPEC-workflow.md is exempt: it is the specification, it predates the
# extraction, and it names what it is separating itself from on purpose.
set -u
cd "$(dirname "$(readlink -f "$0")")"

MOTS='th[eè]me|theme|cr[ée]dits?|credits?|astro|ath[ée]na|patagonia|zodia|horoscop|ephemer|natal'
CIBLES="lib example schema test README.md dune-project"

TROUVE=$(grep -rniE "$MOTS" $CIBLES 2>/dev/null)
if [ -n "$TROUVE" ]; then
  echo "the engine has grown roots into the application it came from:" >&2
  printf '%s\n' "$TROUVE" >&2
  exit 1
fi
echo "separation holds: no domain name in $CIBLES"
