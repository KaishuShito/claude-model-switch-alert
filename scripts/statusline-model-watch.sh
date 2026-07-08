#!/bin/bash
# Optional statusLine watcher. Pass the already-read statusLine JSON as the first
# argument or CLAUDE_MODEL_ALERT_STATUSLINE_JSON so callers can keep using stdin.

claude_model_alert_statusline_return() {
  return "$1" 2>/dev/null || exit "$1"
}

claude_model_alert_statusline_main() {
  local input parsed model session transcript cwd state last script_dir hook synthetic bg_pid
  input="${1:-${CLAUDE_MODEL_ALERT_STATUSLINE_JSON:-}}"
  if [ -z "$input" ] && [ ! -t 0 ]; then
    input=$(cat)
  fi
  [ -n "$input" ] || return 0

  parsed=$(printf '%s' "$input" | jq -r '[.model.id // "", .session_id // "unknown", .transcript_path // "", .workspace.current_dir // .cwd // ""] | @tsv' 2>/dev/null) || return 0
  IFS="$(printf '\t')" read -r model session transcript cwd <<EOF
$parsed
EOF
  [ -n "$model" ] || return 0

  state="${TMPDIR:-/tmp}/claude-model-alert-${session}"
  last=$(sed -n 2p "$state" 2>/dev/null)
  [ "$model" != "$last" ] || return 0

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  hook="${script_dir}/model-switch-alert.sh"
  [ -f "$hook" ] || return 0

  synthetic=$(jq -nc \
    --arg session "$session" \
    --arg transcript "$transcript" \
    --arg cwd "$cwd" \
    --arg model "$model" \
    '{session_id:$session,transcript_path:$transcript,cwd:$cwd,hook_event_name:"StatusLine",model:{id:$model}}') || return 0
  CLAUDE_MODEL_ALERT_STATUSLINE_SYNTHETIC="$synthetic" \
    CLAUDE_MODEL_ALERT_STATUSLINE_HOOK="$hook" \
    nohup bash -c 'printf "%s" "$CLAUDE_MODEL_ALERT_STATUSLINE_SYNTHETIC" | bash "$CLAUDE_MODEL_ALERT_STATUSLINE_HOOK"' >/dev/null 2>&1 &
  bg_pid=$!
  disown "$bg_pid" 2>/dev/null || true
  return 0
}

claude_model_alert_statusline_main "$@"
claude_model_alert_statusline_return $?
