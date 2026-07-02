#!/bin/bash
# Stop hook: detect silent model fallback (e.g. Fable 5 -> Opus 4.8) and alert with sound.
# Staged alerts: switch moment = sonar + voice + Notification Center /
#                while switched = short beep every turn / recovery = fanfare.
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
model=$(tail -n 200 "$transcript" | jq -r 'select(.type == "assistant") | .message.model // empty' 2>/dev/null | grep -v '^<' | tail -n 1)
[ -n "$model" ] || exit 0

# Remember the previous model per session to detect transitions.
state="${TMPDIR:-/tmp}/claude-model-alert-${session}"
prev=$(cat "$state" 2>/dev/null)
printf '%s\n' "$model" > "$state"

speak() {
  say -v Kyoko "$1" 2>/dev/null || say "$2"
}

case "$model" in
  "$expected"*)
    case "$prev" in
      ""|"$expected"*) ;;
      *)
        ( afplay "$SOUND_RECOVER"; speak "元のモデルに戻りました" "Model restored" ) >/dev/null 2>&1 &
        printf '{"systemMessage": "✅ %s に戻りました"}\n' "$expected"
        ;;
    esac
    exit 0
    ;;
esac

if [ "$model" != "$prev" ]; then
  # Just switched: strong alert + Notification Center (persists in history).
  ( afplay "$SOUND_SWITCH"; speak "注意。モデルが切り替わりました" "Warning. Model switched" ) >/dev/null 2>&1 &
  osascript -e "display notification \"${expected} から ${model} に切り替わりました\" with title \"Claude Code: モデル切り替え\" sound name \"Submarine\"" >/dev/null 2>&1 &
  printf '{"systemMessage": "⚠️ モデルが %s から %s に切り替わっています"}\n' "$expected" "$model"
else
  # Still switched: gentle beep every turn until you notice.
  ( afplay "$SOUND_ONGOING" ) >/dev/null 2>&1 &
  printf '{"systemMessage": "⚠️ 引き続き %s で応答中（%s ではありません）"}\n' "$model" "$expected"
fi
exit 0
