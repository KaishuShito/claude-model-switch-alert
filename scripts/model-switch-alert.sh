#!/bin/bash
# Stop hook: detect AUTOMATIC model fallback (e.g. Fable 5 -> Opus 4.8) and alert with sound.
# Manual switches via /model are recognized from their transcript trace ("Set model to ...")
# and skipped silently — the expected baseline follows the user's choice.
# Staged alerts: switch moment = sonar + voice + in-app/OS notification /
#                while switched = short beep every turn / recovery = fanfare.
# See: https://www.anthropic.com/news/redeploying-fable-5
input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
event=$(printf '%s' "$input" | jq -r '.hook_event_name // "Stop"')
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$hook_cwd" ] || hook_cwd="$(pwd)"
[ -f "$transcript" ] || exit 0

# All sounds ship with macOS (/System/Library/Sounds), so this works on any Mac.
SOUND_SWITCH="/System/Library/Sounds/Submarine.aiff"
SOUND_ONGOING="/System/Library/Sounds/Morse.aiff"
SOUND_RECOVER="/System/Library/Sounds/Hero.aiff"

# Hook stdin usually has no model field; read the latest assistant message's model from the transcript.
# StatusLine integration passes model.id through a synthetic event because statusLine stdin has it.
# Exclude sidechain (subagent) messages: subagents may legitimately run on other models
# (e.g. Haiku-powered explorers) and must not trigger a false alarm.
model=$(printf '%s' "$input" | jq -r '.model.id // empty')
[ -n "$model" ] || model=$(tail -n 200 "$transcript" | jq -r 'select(.type == "assistant" and ((.isSidechain // false) | not)) | .message.model // empty' 2>/dev/null | grep -v '^<' | tail -n 1)
[ -n "$model" ] || exit 0

# Per-session state: line 1 = baseline (the model the user chose), line 2 = last seen model.
# The baseline starts as CLAUDE_EXPECTED_MODEL (if set) or the session's first observed model,
# and follows manual /model switches. Alerts fire only when the model leaves the baseline
# without a manual-switch trace.
state="${TMPDIR:-/tmp}/claude-model-alert-${session}"
baseline=$(sed -n 1p "$state" 2>/dev/null)
last=$(sed -n 2p "$state" 2>/dev/null)
[ -n "$baseline" ] || baseline="${CLAUDE_EXPECTED_MODEL:-$model}"
[ -n "$last" ] || last="$baseline"

save() { printf '%s\n%s\n' "$baseline" "$model" > "$state"; }

speak() {
  say -v Kyoko "$1" 2>/dev/null || say "$2"
}

# Machine-wide sound cooldown: with many parallel sessions (e.g. 100 Cockpit tasks),
# individual per-session alerts would stack into an alarm storm. Only the first alert
# within the window makes noise; the rest stay visual-only (systemMessage).
# Set CLAUDE_MODEL_ALERT_COOLDOWN=0 to disable.
cooldown="${CLAUDE_MODEL_ALERT_COOLDOWN:-30}"
sound_ok() {
  [ "$cooldown" -le 0 ] 2>/dev/null && return 0
  local gate now last_sound
  gate="${TMPDIR:-/tmp}/claude-model-alert-sound-gate"
  now=$(date +%s)
  last_sound=$(cat "$gate" 2>/dev/null || echo 0)
  [ $((now - last_sound)) -ge "$cooldown" ] || return 1
  printf '%s\n' "$now" > "$gate"
  return 0
}

cockpit_task_json() {
  [ -n "${AGI_COCKPIT_TASK_ID:-}" ] || return 1
  command -v cockpit >/dev/null 2>&1 || return 1
  local tmp pid killer rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-model-alert-cockpit.XXXXXX") || return 1
  cockpit task get "$AGI_COCKPIT_TASK_ID" > "$tmp" 2>/dev/null &
  pid=$!
  ( sleep 2; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid"
  rc=$?
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

context_task_name=""
context_label=""
ensure_context() {
  [ -n "$context_label" ] && return
  if task_json=$(cockpit_task_json); then
    context_task_name=$(printf '%s' "$task_json" | jq -r 'if .ok == true and (.data | type == "object") then (.data.name // empty) else empty end' 2>/dev/null)
  fi
  if [ -n "$context_task_name" ]; then
    context_label="$context_task_name"
  else
    context_label="$(basename "$hook_cwd")"
    [ -n "$context_label" ] || context_label="$hook_cwd"
  fi
}

context_label() {
  ensure_context
  printf '%s' "$context_label"
}

notification_context_suffix() {
  ensure_context
  if [ -n "$context_task_name" ]; then
    printf '（タスク: %s / %s）' "$context_task_name" "$hook_cwd"
  else
    printf '（%s）' "$hook_cwd"
  fi
}

# Show the alert in AGI Cockpit if its CLI is available and the app responds.
# Returns 0 when shown in Cockpit, 1 when it fell back to macOS Notification Center.
notify() {
  local title text
  ensure_context
  title="Claude Code: モデル切り替え — $context_label"
  text="${1}$(notification_context_suffix)"
  if command -v cockpit >/dev/null 2>&1; then
    if cockpit display --text "$text" --title "$title" 2>/dev/null | grep -q '"ok":true'; then
      return 0
    fi
  fi
  osascript - "$text" "$title" >/dev/null 2>&1 <<'OSA'
on run argv
  display notification (item 1 of argv) with title (item 2 of argv) sound name "Submarine"
end run
OSA
  return 1
}

# Detect a manual model switch: a user-side trace like "Set model to ..." (the
# /model command output) appearing after the last assistant message that used a
# model different from the current one. Automatic fallbacks leave no such trace.
manual_switch() {
  tail -n 2000 "$transcript" | jq -r '
    if .type == "assistant" and ((.isSidechain // false) | not) then
      "A \(.message.model // "?")"
    elif .type == "user" and ((.message.content // "" | tostring) |
      (contains("Set model to") or contains("<command-name>/model") or contains("<command-name>/fast"))) then
      "M"
    else empty end' 2>/dev/null | awk -v new="$model" '
      $1 == "A" { i++; ev[i] = ($2 == new) ? "same" : "diff" }
      $1 == "M" { i++; ev[i] = "M" }
      END {
        lastdiff = 0
        for (j = 1; j <= i; j++) if (ev[j] == "diff") lastdiff = j
        for (j = lastdiff + 1; j <= i; j++) if (ev[j] == "M") { print "manual"; exit }
      }'
}

transition_only_event() {
  case "$event" in
    PostToolUse|StatusLine) return 0 ;;
    *) return 1 ;;
  esac
}

case "$model" in
  "$baseline"*)
    case "$last" in
      "$baseline"*) ;;
      *)
        if sound_ok; then
          ( afplay "$SOUND_RECOVER"; speak "元のモデルに戻りました" "Model restored" ) >/dev/null 2>&1 &
        fi
        printf '{"systemMessage": "✅ %s に戻りました"}\n' "$baseline"
        ;;
    esac
    save
    exit 0
    ;;
esac

if [ "$model" != "$last" ]; then
  if [ -n "$(manual_switch)" ]; then
    # The user switched models on purpose; follow silently.
    baseline="$model"
    save
    exit 0
  fi
  # Automatic switch: strong alert + in-app (Cockpit) or OS notification.
  extra=""
  if sound_ok; then
    ( afplay "$SOUND_SWITCH"; speak "注意。モデルが切り替わりました" "Warning. Model switched" ) >/dev/null 2>&1 &
    if ! notify "⚠️ ${baseline} から ${model} に切り替わりました"; then
      # Cockpit がない環境では、初回だけ一行そっと存在を知らせる（音・ポップアップなし、二度と出ない）
      hint_marker="$HOME/.claude/.model-switch-alert-cockpit-hint"
      if [ ! -f "$hint_marker" ]; then
        touch "$hint_marker" 2>/dev/null
        extra="\n💡 AGI Cockpit ならこのアラートをアプリ内表示にできます → https://agi-labo.com/tools/cockpit?utm_source=claude-code&utm_medium=plugin&utm_campaign=model-switch-alert-202607&utm_content=hint-line （この案内は今回限りです）"
      fi
    fi
  fi
  printf '{"systemMessage": "⚠️ モデルが %s から %s に切り替わっています%s"}\n' "$baseline" "$model" "$extra"
else
  if transition_only_event; then
    exit 0
  fi
  # Still switched: gentle beep every turn until you notice.
  if sound_ok; then
    ( afplay "$SOUND_ONGOING" ) >/dev/null 2>&1 &
  fi
  printf '{"systemMessage": "⚠️ 引き続き %s で応答中（%s ではありません）"}\n' "$model" "$baseline"
fi
save
exit 0
