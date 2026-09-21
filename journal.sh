#!/bin/bash
# Journal des travaux. Usage : ./journal.sh NIVEAU "message"
# Niveaux : INFO WARN ERROR RESULT ACTION
# Format : ISO-8601 avec fuseau, comme syslog. Jamais tronqué.
LOG="$(dirname "$(readlink -f "$0")")/travaux.log"
NIVEAU="${1:-INFO}"; shift
printf '%s [%-6s] %s\n' "$(date -Is)" "$NIVEAU" "$*" >> "$LOG"
