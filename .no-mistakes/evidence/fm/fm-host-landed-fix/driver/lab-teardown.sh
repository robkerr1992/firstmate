#!/usr/bin/env bash
# Live lab driver: builds a disposable marked FM_HOME with a real git origin, a
# real treehouse pool slot, a private tmux server, the real gh login, then runs
# bin/fm-teardown.sh as the named actor and records the observable outcome.
# Usage: lab-teardown.sh <name> <actor:main|branch> <pr:open|merged> <wt:present|gone> [gh:ok|broken] [bin-dir]
set -u
NAME=$1 ACTOR=$2 PR=$3 WTMODE=$4 GH=${5:-ok} BIN=${6:-$ROOT/bin}
EV=${EV:?}; OUT="$EV/live/$NAME"; mkdir -p "$OUT"
OPEN_PR=https://github.com/cli/cli/pull/14727
MERGED_PR=https://github.com/robkerr1992/wrinkle/pull/27
MERGED_HEAD=3c2873e4a1ee9c75ea9cac4ce2f43fe09e67279b
log() { printf '%s\n' "$*" | tee -a "$OUT/transcript.txt"; }
run() { log "\$ $*"; "$@" 2>&1 | tee -a "$OUT/transcript.txt"; return "${PIPESTATUS[0]}"; }

LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/pool"; touch "$LAB/state/.last-watcher-beat"
trap 'TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
log "# lab home: $LAB (actor=$ACTOR pr=$PR worktree=$WTMODE gh=$GH bin=$BIN)"

# --- real git origin + project clone ---
if [ "$PR" = merged ]; then
  PR_URL=$MERGED_PR
  gh repo clone robkerr1992/wrinkle "$LAB/origin.git" -- --bare -q >/dev/null 2>&1 || { log "clone failed"; exit 1; }
  git -C "$LAB/origin.git" fetch -q https://github.com/robkerr1992/wrinkle.git "refs/pull/27/head:refs/heads/fm/task-x1" || { log "pull-ref fetch failed"; exit 1; }
else
  PR_URL=$OPEN_PR
  git init -q --bare "$LAB/origin.git"; git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$LAB/origin.git" "$LAB/_seed" 2>/dev/null
  git -C "$LAB/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$LAB/_seed" push -q origin main; rm -rf "$LAB/_seed"
fi
git clone -q "$LAB/origin.git" "$LAB/project"
git -C "$LAB/project" remote set-head origin main 2>/dev/null || true

# --- real treehouse pool slot on the task branch ---
if [ "$PR" = merged ]; then
  WT=$(cd "$LAB/project" && TREEHOUSE_ROOT="$LAB/pool" treehouse get --lease --lease-holder task-x1 --base fm/task-x1 -b fm/task-x1-wt 2>"$OUT/treehouse-get.err") || { log "treehouse get failed: $(cat "$OUT/treehouse-get.err")"; exit 1; }
  [ "$(git -C "$WT" rev-parse HEAD)" = "$MERGED_HEAD" ] || { log "worktree HEAD is not the PR head"; exit 1; }
else
  WT=$(cd "$LAB/project" && TREEHOUSE_ROOT="$LAB/pool" treehouse get --lease --lease-holder task-x1 -b fm/task-x1 2>"$OUT/treehouse-get.err") || { log "treehouse get failed: $(cat "$OUT/treehouse-get.err")"; exit 1; }
  printf 'hello\n' > "$WT/feature.txt"; git -C "$WT" add feature.txt
  git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  git -C "$WT" push -q origin fm/task-x1; git -C "$LAB/project" fetch -q origin
fi
log "# worktree $WT at $(git -C "$WT" rev-parse --short HEAD); on remote: $(git -C "$WT" branch -r --contains HEAD | tr '\n' ' ')"

# --- task record, backlog row, tmux window (private server) ---
META_WT=$WT; [ "$WTMODE" = present ] || META_WT="$LAB/gone-worktree"
printf '%s\n' "window=fmlab:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$META_WT" \
  "project=$LAB/project" "kind=ship" "mode=direct-PR" "spawn_gen=lab-task-x1" > "$LAB/state/task-x1.meta"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tasks-axi add task-x1 "lab ship task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null
TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s fmlab -n fm-task-x1 -c "$LAB" || exit 1

# --- record the PR and arm its merge poll with the real forge, as fm-pr-check does ---
if [ "$WTMODE" = present ]; then
  run env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" "$ROOT/bin/fm-pr-check.sh" task-x1 "$PR_URL" || log "(fm-pr-check exit $?)"
else
  printf 'pr=%s\n' "$PR_URL" >> "$LAB/state/task-x1.meta"
  log "# worktree path recorded as gone ($META_WT); pr=$PR_URL recorded on the task record"
fi
log "# before: state=[$(cd "$LAB/state" && ls task-x1* | tr '\n' ' ')] backlog=$(tasks-axi show task-x1 --file "$LAB/data/backlog.md" | sed -n 's/^  state: *//p' | head -1)"
log "# before: live forge says $(gh pr view "$PR_URL" --json state -q .state) for $PR_URL"

# --- the teardown under test ---
GH_UNSET=() GH_SET=()
if [ "$GH" = broken ]; then
  mkdir -p "$LAB/gh-nocreds"; GH_UNSET=(-u GH_TOKEN -u GITHUB_TOKEN); GH_SET=(GH_CONFIG_DIR="$LAB/gh-nocreds")
  log "# gh is pointed at an empty config dir so every forge read errors (no login mutation):"
  log "\$ GH_CONFIG_DIR=\$LAB/gh-nocreds gh pr view $PR_URL --json state"
  (env "${GH_UNSET[@]}" "${GH_SET[@]}" gh pr view "$PR_URL" --json state; echo "(gh exit $?)") 2>&1 | tee -a "$OUT/transcript.txt"
fi
log "\$ FM_HOME=\$LAB FM_SUPERVISION_ACTOR=$ACTOR $BIN/fm-teardown.sh task-x1"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE "${GH_UNSET[@]}" \
  "${GH_SET[@]}" FM_HOME="$LAB" FM_SUPERVISION_ACTOR="$ACTOR" TMUX_TMPDIR="$LAB/tmux" TREEHOUSE_ROOT="$LAB/pool" \
  "$BIN/fm-teardown.sh" task-x1 > "$OUT/teardown.stdout" 2> "$OUT/teardown.stderr"
RC=$?
log "# teardown exit=$RC"
log "# --- stdout ---"; cat "$OUT/teardown.stdout" | tee -a "$OUT/transcript.txt"
log "# --- stderr ---"; cat "$OUT/teardown.stderr" | tee -a "$OUT/transcript.txt"
log "# after: state=[$(cd "$LAB/state" && ls task-x1* 2>/dev/null | tr '\n' ' ')]"
log "# after: backlog=$(tasks-axi show task-x1 --file "$LAB/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)"
log "# after: tmux windows=[$(TMUX_TMPDIR="$LAB/tmux" tmux list-windows -t fmlab -F '#W' 2>/dev/null | tr '\n' ' ')]"
log "# after: worktree feature present=$([ -e "$WT/feature.txt" ] && echo yes || echo no); treehouse status:"
(cd "$LAB/project" && TREEHOUSE_ROOT="$LAB/pool" treehouse status 2>&1) | grep -v "treehouse is available\|treehouse update" | tee -a "$OUT/transcript.txt"
printf '%s\n' "$RC" > "$OUT/exit"
exit 0
