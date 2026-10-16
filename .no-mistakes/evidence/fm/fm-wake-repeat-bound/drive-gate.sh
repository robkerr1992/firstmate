#!/usr/bin/env bash
# Drives bin/fm-supervision-gate.sh + fm-branch-outcome.sh against a throwaway home.
set -u
R=$1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate-lab.XXXXXX")
. "$R/tests/wake-helpers.sh" >/dev/null 2>&1 || true
mkdir -p "$H/state" "$H/config"
printf 'window=test:fm-demo\n' > "$H/state/demo.meta"
printf 'working [at=1]: idle at its prompt\n' > "$H/state/demo.status"
export FM_HOME="$H"
"$R/bin/fm-branch-outcome.sh" append --task demo --verdict routine --silent true --summary 'idle; no action' >/dev/null
wake() { append_wake "$H/state" stale test:fm-demo 'stale: test:fm-demo'; awk -F '\t' '$3=="stale"{s=$2} END{print s}' "$H/state/.wake-queue"; }
echo "== six consecutive unchanged stale wakes (FM_SUPERVISION_GATE_SKIPS=0 / WINDOW=1 set and must be ignored) =="
for i in 1 2 3 4 5 6; do
  seq=$(wake)
  out=$(FM_SUPERVISION_GATE_SKIPS=0 FM_SUPERVISION_GATE_WINDOW=1 FM_SUPERVISION_JUDGE_TIMEOUT=1 "$R/bin/fm-supervision-gate.sh" decide --task demo --posture away --rows "$seq")
  echo "-- wake $i (row $seq)"; echo "$out"
  d=$(echo "$out" | sed -n 's/^decision=//p')
  if [ "$d" = skip ]; then "$R/bin/fm-branch-outcome.sh" append --task demo --verdict routine --silent true --summary "$(echo "$out"|sed -n 's/^summary=//p')" >/dev/null; fi
done
echo; echo "== status append -> turn =="
printf 'working [at=2]: decided X\n' >> "$H/state/demo.status"
seq=$(wake); "$R/bin/fm-supervision-gate.sh" decide --task demo --posture away --rows "$seq"
echo; echo "== fresh silent outcome, judge on -> judge sees JSON =="
"$R/bin/fm-branch-outcome.sh" append --task demo --verdict routine --silent true --summary 'idle again' >/dev/null
printf '#!/bin/sh\ncat > "%s/judge-in.json"\necho skip\n' "$H" > "$H/judge"; chmod +x "$H/judge"
echo "on judge" > "$H/config/supervision-judge"
seq=$(wake); "$R/bin/fm-supervision-gate.sh" decide --task demo --posture away --rows "$seq"
echo "-- judge stdin:"; jq . "$H/judge-in.json"
echo; echo "== shadow mode with a skip-saying judge -> still turn =="
echo "shadow judge" > "$H/config/supervision-judge"
"$R/bin/fm-supervision-gate.sh" decide --task demo --posture away --rows "$seq"
echo; echo "== on judge printing garbage -> turn =="
printf '#!/bin/sh\necho maybe\n' > "$H/judge"; echo "on judge" > "$H/config/supervision-judge"
"$R/bin/fm-supervision-gate.sh" decide --task demo --posture away --rows "$seq"
echo; echo "== attended with captain words in mirror -> turn =="
rm -f "$H/config/supervision-judge"; printf '[captain] stop that\n' > "$H/mirror"
"$R/bin/fm-supervision-gate.sh" decide --task demo --posture attended --rows "$seq" --mirror-file "$H/mirror"
rm -rf "$H"
