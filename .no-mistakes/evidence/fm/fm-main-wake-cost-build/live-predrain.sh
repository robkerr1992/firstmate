#!/usr/bin/env bash
# Live scenario: real Claude Code + tracked hooks + real fm-wake-drain.sh/fm-wake-ack.sh.
# Arm fixture closes: 1) empty check: rearm-resurface (expect absorbed, no wake),
# 2) signal with a real queued row (expect one pre-drained wake, model uses no tools,
# turn-end Stop commits the ack), 3) clean close ending the need.
set -u
ROOT="$1"; EVID="$2"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
PROJECT="$LAB/project"; H="$LAB/fmhome"; T="$EVID/live-transcript.jsonl"
trap 'rm -rf "$LAB"' EXIT
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"; cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{"hooks":{
 "PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"jq -c '{tool:.tool_name,input:.tool_input}' >> \"$FM_HOME/state/tool-calls.log\"; exit 0"}]}],
 "UserPromptSubmit":[{"hooks":[{"type":"command","command":"jq -c '{t:now,prompt:.prompt}' >> \"$FM_HOME/state/prompts.log\"; exit 0"}]}]
}}
JSON
mkdir -p "$H/state" "$H/config" "$H/data"
: > "$H/config/supervision-host-off"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$H/state/task.meta"
printf '9999999\n' > "$H/state/.lock"
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then printf 'watcher: started pid=%s (beacon fresh)\n' "$$"; exit 0; fi
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$ ppid=$PPID t=$(date +%s)" >> "$FM_HOME/state/arm-ran"
touch "$FM_HOME/state/.last-watcher-beat"
case "$N" in
  1) printf 'pending:downtime:live-gen-1\n' > "$FM_HOME/state/.watcher-down"
     printf 'watcher: started pid=%s (beacon fresh)\ncheck: rearm-resurface\n' "$$" ;;
  2) FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '. "$1"; fm_wake_append signal live-row "signal: LIVE-ROW-42 crew fixture finished"' _ "$(dirname "$0")/fm-wake-lib.sh"
     printf 'watcher: started pid=%s (beacon fresh)\nsignal: LIVE-ROW-42 crew fixture finished\n' "$$" ;;
  *) rm -f "$FM_HOME/state/task.meta"; printf 'watcher: attached pid=%s (beacon 2s)\n' "$$" ;;
esac
exit 0
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh"
PROMPT='Reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, do NOT use any tool at all; reply with exactly ACK followed by every token starting with LIVE- that the message shows, then stop.'
( cd "$PROJECT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$H" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
  claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' --effort low --output-format stream-json --verbose ) > "$T" 2>&1
echo "claude rc=$?"
for f in arm-ran wake-ack.log prompts.log tool-calls.log .claude-autoarm-epoch .watcher-down; do echo "=== $f"; cat "$H/state/$f" 2>/dev/null; done
echo "=== pending record left?"; ls -la "$H/state/.wake-ack-pending"* 2>&1
echo "=== queue file"; cat "$H/state/.wake-queue" "$H/state/wake-queue"* 2>/dev/null; ls "$H/state"
echo "=== post-run plain drain (what main would see now)"
( cd "$PROJECT" && env -u FM_STATE_OVERRIDE FM_HOME="$H" bin/fm-wake-drain.sh 2>&1 ); echo "drain rc=$?"
