#!/bin/bash
# Stop hook: detect silent model fallback (e.g. Fable 5 -> Opus 4.8) and alert with sound.
# Staged alerts: switch moment = sonar + voice + in-app/OS notification /
#                while switched = short beep every turn / recovery = fanfare.
# If AGI Cockpit is available, the alert is shown as a frontmost display inside Cockpit;
# otherwise it falls back to macOS Notification Center.
# See: https://www.anthropic.com/news/redeploying-fable-5
input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
[ -f "$transcript" ] || exit 0

# The expected model. Override with CLAUDE_EXPECTED_MODEL if you run a different one.
expected="${CLAUDE_EXPECTED_MODEL:-claude-fable-5}"

# All sounds ship with macOS (/System/Library/Sounds), so this works on any Mac.
SOUND_SWITCH="/System/Library/Sounds/Submarine.aiff"
SOUND_ONGOING="/System/Library/Sounds/Morse.aiff"
SOUND_RECOVER="/System/Library/Sounds/Hero.aiff"

# Hook stdin has no model field; read the latest assistant message's model from the transcript.
# Exclude sidechain (subagent) messages: subagents may legitimately run on other models
# (e.g. Haiku-powered explorers) and must not trigger a false alarm.
model=$(tail -n 200 "$transcript" | jq -r 'select(.type == "assistant" and ((.isSidechain // false) | not)) | .message.model // empty' 2>/dev/null | grep -v '^<' | tail -n 1)
[ -n "$model" ] || exit 0

# Remember the previous model per session to detect transitions.
state="${TMPDIR:-/tmp}/claude-model-alert-${session}"
prev=$(cat "$state" 2>/dev/null)
printf '%s\n' "$model" > "$state"

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
  local gate now last
  gate="${TMPDIR:-/tmp}/claude-model-alert-sound-gate"
  now=$(date +%s)
  last=$(cat "$gate" 2>/dev/null || echo 0)
  [ $((now - last)) -ge "$cooldown" ] || return 1
  printf '%s\n' "$now" > "$gate"
  return 0
}

# Show the alert in AGI Cockpit if its CLI is available and the app responds.
# Returns 0 when shown in Cockpit, 1 when it fell back to macOS Notification Center.
notify() {
  if command -v cockpit >/dev/null 2>&1; then
    if cockpit display --text "$1" --title "Claude Code: モデル切り替え" 2>/dev/null | grep -q '"ok":true'; then
      return 0
    fi
  fi
  osascript -e "display notification \"$1\" with title \"Claude Code: モデル切り替え\" sound name \"Submarine\"" >/dev/null 2>&1
  return 1
}

case "$model" in
  "$expected"*)
    case "$prev" in
      ""|"$expected"*) ;;
      *)
        if sound_ok; then
          ( afplay "$SOUND_RECOVER"; speak "元のモデルに戻りました" "Model restored" ) >/dev/null 2>&1 &
        fi
        printf '{"systemMessage": "✅ %s に戻りました"}\n' "$expected"
        ;;
    esac
    exit 0
    ;;
esac

if [ "$model" != "$prev" ]; then
  # Just switched: strong alert + in-app (Cockpit) or OS notification.
  extra=""
  if sound_ok; then
    ( afplay "$SOUND_SWITCH"; speak "注意。モデルが切り替わりました" "Warning. Model switched" ) >/dev/null 2>&1 &
    if ! notify "⚠️ ${expected} から ${model} に切り替わりました"; then
      # Cockpit がない環境では、初回だけ一行そっと存在を知らせる（音・ポップアップなし、二度と出ない）
      hint_marker="$HOME/.claude/.model-switch-alert-cockpit-hint"
      if [ ! -f "$hint_marker" ]; then
        touch "$hint_marker" 2>/dev/null
        extra="\n💡 AGI Cockpit ならこのアラートをアプリ内表示にできます → https://agi-labo.com/tools/cockpit （この案内は今回限りです）"
      fi
    fi
  fi
  printf '{"systemMessage": "⚠️ モデルが %s から %s に切り替わっています%s"}\n' "$expected" "$model" "$extra"
else
  # Still switched: gentle beep every turn until you notice.
  if sound_ok; then
    ( afplay "$SOUND_ONGOING" ) >/dev/null 2>&1 &
  fi
  printf '{"systemMessage": "⚠️ 引き続き %s で応答中（%s ではありません）"}\n' "$model" "$expected"
fi
exit 0
