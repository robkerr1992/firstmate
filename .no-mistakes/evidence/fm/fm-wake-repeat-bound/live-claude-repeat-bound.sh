#!/usr/bin/env bash
# Live drive: the real supervision host with the REAL installed Claude engine (no stub),
# in a disposable lab copy of the run worktree. An idle worker's pane changes cosmetically:
# wake 1 -> real Claude turn; wake 2 (unchanged repeat) -> expected repeat-bound skip with
# no engine turn; then a status append -> real Claude turn again.
set -u
WT=$1
. "$WT/tests/wake-helpers.sh"
LAB=$(fm_test_tmproot fm-live-repeat-bound); LAB=$(cd -P "$LAB" && pwd -P); FM="$LAB/fm"
mkdir -p "$LAB/harness"; ln -s /bin/bash "$LAB/harness/claude"; FAKE_CLAUDE="$LAB/harness/claude"
stop_lab() { local pid
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host" 2>/dev/null); [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null; sleep 2
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null); [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null
  while IFS= read -r pid; do kill -TERM "$pid" 2>/dev/null; done < "$LAB/claude-pids" 2>/dev/null; }
trap 'stop_lab; fm_test_cleanup' EXIT
mkdir -p "$FM"
git -C "$WT" ls-files -z -co --exclude-standard | (cd "$WT" && tar --null -T - -cf -) | (cd "$FM" && tar -xf -)
git -C "$FM" init -q -b main; git -C "$FM" add -A >/dev/null
git -C "$FM" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$FM/state" "$FM/config"; : > "$FM/config/supervision-host"
TMP_ROOT="$LAB"; mk=$(make_case tmuxcase); FB="$LAB/fakebin"; mkdir -p "$FB"; cp "$mk/fakebin/tmux" "$FB/tmux"; make_fake_crew_state "$FB" >/dev/null
printf 'project=demo\nwindow=test:fm-demo\nharness=claude\n' > "$FM/state/demo.meta"
printf 'working [at=1]: idle at its prompt, waiting for the next brief; nothing to do\n' > "$FM/state/demo.status"
prime_status_seen "$FM/state" "$FM/state/demo.status"
printf 'idle prompt, clock 10:00' > "$LAB/pane"
FM_HOME="$FM" "$FM/bin/fm-afk-contract.sh" enter --words 'Watch the fleet. Merge nothing and dispatch nothing. An idle worker needs no action.' >/dev/null || fail "away posture"
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_FAKE_TMUX_WINDOW=test:fm-demo FM_FAKE_TMUX_CAPTURE="$LAB/pane"
unset FM_SUPERVISION_ENGINE_CLAUDE_BIN FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN FM_LEASE_HOLDER_PID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE PI_CODING_AGENT
FM_HOME="$FM" FM_CREW_STATE_BIN="$FB/fm-crew-state.sh" PATH="$FB:$PATH" "$FAKE_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"; printf "%s\n" "$$" >> "$1/claude-pids"
  "$FM_HOME/bin/fm-supervision-host.sh" park > "$1/host.out" 2>&1; printf "%s\n" "$?" > "$1/host.rc"' _ "$LAB" 2>> "$LAB/harness.err" &
wait_until() { local l=$1 i=0; shift; while [ $i -lt $l ]; do "$@" && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
n() { grep -cE "	$1	" "$FM/state/.supervision-host.log" 2>/dev/null || true; }
ge() { [ "$(n "$1")" -ge "$2" ] || [ -s "$LAB/host.rc" ]; }
dump() { echo "--- host ledger"; cat "$FM/state/.supervision-host.log"; echo "--- outcome store"; jq -c '{seq,task,verdict,silent,summary}' "$FM/state/branch-outcomes.jsonl"; echo "--- queue"; cat "$FM/state/.wake-queue" 2>/dev/null; echo "--- host.rc: $(cat "$LAB/host.rc" 2>/dev/null)"; echo "--- host.out"; tail -20 "$LAB/host.out"; }
echo "# claude: $(claude --version | head -1)"
wait_until 3000 sh -c 'grep -qE "	(handled|failed)	" "$0" 2>/dev/null' "$FM/state/.supervision-host.log" || { dump; fail "wake 1 never settled"; }
echo "# wake 1 settled"; dump
printf 'idle prompt, clock 10:04' > "$LAB/pane"
wait_until 3000 sh -c '[ "$(grep -cE "	(handled|failed|skipped)	" "$0")" -ge 2 ]' "$FM/state/.supervision-host.log" || { dump; fail "wake 2 never settled"; }
echo "# wake 2 settled"; dump
printf 'working [at=%s]: started the follow-up check\n' "$(date +%s)" >> "$FM/state/demo.status"
wait_until 3000 sh -c '[ "$(grep -cE "	(handled|failed|skipped)	" "$0")" -ge 3 ]' "$FM/state/.supervision-host.log" || { dump; fail "wake 3 never settled"; }
echo "# wake 3 settled"; dump
echo "# engine conversation: $(cat "$FM/state/.supervision-host-engine" 2>/dev/null | tr '\n' ' ')"
