#!/bin/bash
# 動作テスト: 自動フォールバック、PostToolUse、statusLine、手動切替スキップを検査する。
#
# 使い方（プラグインインストール後）:
#   bash ~/.claude/plugins/cache/kai-market/model-switch-alert/*/scripts/test-alert.sh
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
hook="${script_dir}/model-switch-alert.sh"
status_watch="${script_dir}/statusline-model-watch.sh"
[ -f "$hook" ] || { echo "model-switch-alert.sh が見つかりません"; exit 1; }
[ -f "$status_watch" ] || { echo "statusline-model-watch.sh が見つかりません"; exit 1; }

tmp_root=$(mktemp -d)
bin_dir="$tmp_root/bin"
home_dir="$tmp_root/home"
log="$tmp_root/events.log"
mkdir -p "$bin_dir" "$home_dir/.claude"
export PATH="$bin_dir:$PATH"
export HOME="$home_dir"
export CLAUDE_MODEL_ALERT_COOLDOWN=0

cat > "$bin_dir/afplay" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$bin_dir/say" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$bin_dir/osascript" <<'EOF'
#!/bin/bash
printf 'osascript\t%s\n' "$*" >> "$MODEL_SWITCH_TEST_LOG"
cat >/dev/null
exit 0
EOF
cat > "$bin_dir/cockpit" <<'EOF'
#!/bin/bash
case "$1:$2" in
  task:get)
    printf '{"ok":true,"data":{"id":"%s","name":"Yota Review Task","directory":"/tmp/yota-task"}}\n' "$3"
    ;;
  display:*)
    text="" title=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --text) shift; text="$1" ;;
        --title) shift; title="$1" ;;
      esac
      shift
    done
    printf 'cockpit-display\t%s\t%s\n' "$title" "$text" >> "$MODEL_SWITCH_TEST_LOG"
    printf '{"ok":true}\n'
    ;;
  *)
    printf '{"ok":false}\n'
    exit 1
    ;;
esac
EOF
chmod +x "$bin_dir/afplay" "$bin_dir/say" "$bin_dir/osascript" "$bin_dir/cockpit"
export MODEL_SWITCH_TEST_LOG="$log"

pass_count=0
fail_count=0

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf 'not ok - %s\n' "$1"
}

assert_contains() {
  if printf '%s' "$1" | grep -Fq "$2"; then
    pass "$3"
  else
    fail "$3"
    printf '  expected to contain: %s\n  actual: %s\n' "$2" "$1"
  fi
}

assert_empty() {
  if [ -z "$1" ]; then
    pass "$2"
  else
    fail "$2"
    printf '  expected empty, actual: %s\n' "$1"
  fi
}

assert_log_count() {
  local expected actual label
  expected="$1"
  label="$2"
  actual=$(grep -c '^cockpit-display' "$log" 2>/dev/null || true)
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label"
    printf '  expected cockpit-display count %s, actual %s\n' "$expected" "$actual"
    sed 's/^/  log: /' "$log" 2>/dev/null || true
  fi
}

wait_log_count() {
  local expected label actual i
  expected="$1"
  label="$2"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    actual=$(grep -c '^cockpit-display' "$log" 2>/dev/null || true)
    [ "$actual" = "$expected" ] && break
    sleep 0.5
  done
  assert_log_count "$expected" "$label"
}

write_baseline() {
  local transcript="$1"
  printf '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}\n' > "$transcript"
}

write_auto_switch() {
  local transcript="$1"
  printf '%s\n%s\n%s\n' \
    '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}' \
    '{"type":"user","message":{"content":"(automatic fallback simulation)"}}' \
    '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[]}}' > "$transcript"
}

write_manual_switch() {
  local transcript="$1"
  printf '%s\n%s\n%s\n' \
    '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}' \
    '{"type":"user","message":{"content":"Set model to claude-opus-4-8"}}' \
    '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[]}}' > "$transcript"
}

payload() {
  local session="$1" transcript="$2" event="$3" cwd="$4"
  jq -nc --arg sid "$session" --arg t "$transcript" --arg event "$event" --arg cwd "$cwd" \
    '{session_id:$sid,transcript_path:$t,hook_event_name:$event,cwd:$cwd}'
}

status_payload() {
  local session="$1" transcript="$2" model="$3" cwd="$4"
  jq -nc --arg sid "$session" --arg t "$transcript" --arg model "$model" --arg cwd "$cwd" \
    '{session_id:$sid,transcript_path:$t,model:{id:$model},workspace:{current_dir:$cwd}}'
}

reset_log() {
  : > "$log"
}

echo "1/4 Stop: 切替通知にタスク名とcwdが載る"
reset_log
dir1="$tmp_root/stop-case"
mkdir -p "$dir1"
t1="$dir1/transcript.jsonl"
sid1="test-stop-$$"
export AGI_COCKPIT_TASK_ID="task-123"
write_baseline "$t1"
payload "$sid1" "$t1" Stop "$dir1" | bash "$hook" >/dev/null
write_auto_switch "$t1"
out=$(payload "$sid1" "$t1" Stop "$dir1" | bash "$hook")
sleep 0.2
log_text=$(cat "$log" 2>/dev/null || true)
assert_contains "$log_text" "Claude Code: モデル切り替え — Yota Review Task" "Stop title includes resolved task name"
assert_contains "$log_text" "（タスク: Yota Review Task / ${dir1}）" "Stop notification body includes task and cwd"
assert_contains "$out" "モデルが claude-fable-5 から claude-opus-4-8" "Stop keeps systemMessage behavior"

echo "2/4 PostToolUse: 遷移時のみ通知、非遷移は無音無出力"
reset_log
dir2="$tmp_root/post-tool-use-case"
mkdir -p "$dir2"
t2="$dir2/transcript.jsonl"
sid2="test-post-$$"
write_baseline "$t2"
payload "$sid2" "$t2" Stop "$dir2" | bash "$hook" >/dev/null
write_auto_switch "$t2"
out=$(payload "$sid2" "$t2" PostToolUse "$dir2" | bash "$hook")
sleep 0.2
assert_contains "$out" "モデルが claude-fable-5 から claude-opus-4-8" "PostToolUse emits on transition"
assert_log_count 1 "PostToolUse notifies once on transition"
out=$(payload "$sid2" "$t2" PostToolUse "$dir2" | bash "$hook")
sleep 0.2
assert_empty "$out" "PostToolUse same-model path outputs nothing"
assert_log_count 1 "PostToolUse same-model path stays silent"

echo "3/4 statusLine: 変化時のみバックグラウンド発火"
reset_log
dir3="$tmp_root/statusline-case"
mkdir -p "$dir3"
t3="$dir3/transcript.jsonl"
sid3="test-status-$$"
write_baseline "$t3"
payload "$sid3" "$t3" Stop "$dir3" | bash "$hook" >/dev/null
write_auto_switch "$t3"
out=$(bash "$status_watch" "$(status_payload "$sid3" "$t3" "claude-opus-4-8" "$dir3")")
assert_empty "$out" "statusLine watcher writes nothing to stdout"
wait_log_count 1 "statusLine watcher notifies on model change"
out=$(bash "$status_watch" "$(status_payload "$sid3" "$t3" "claude-opus-4-8" "$dir3")")
assert_empty "$out" "statusLine unchanged path writes nothing"
wait_log_count 1 "statusLine unchanged path does not notify again"

echo "4/4 手動切替スキップ: Stop/PostToolUse/statusLine"
for event in Stop PostToolUse StatusLine; do
  reset_log
  dir="$tmp_root/manual-$event"
  mkdir -p "$dir"
  t="$dir/transcript.jsonl"
  sid="test-manual-$event-$$"
  write_baseline "$t"
  payload "$sid" "$t" Stop "$dir" | bash "$hook" >/dev/null
  write_manual_switch "$t"
  if [ "$event" = "StatusLine" ]; then
    out=$(bash "$status_watch" "$(status_payload "$sid" "$t" "claude-opus-4-8" "$dir")")
    sleep 4
  else
    out=$(payload "$sid" "$t" "$event" "$dir" | bash "$hook")
    sleep 0.2
  fi
  assert_empty "$out" "manual switch $event outputs nothing"
  assert_log_count 0 "manual switch $event sends no notification"
done

find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'claude-model-alert-test-*' -delete 2>/dev/null || true

if [ "$fail_count" -eq 0 ]; then
  printf 'テスト完了: %s passed, %s failed\n' "$pass_count" "$fail_count"
  exit 0
fi

printf 'テスト失敗: %s passed, %s failed\n' "$pass_count" "$fail_count"
exit 1
