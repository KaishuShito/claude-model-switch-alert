#!/bin/bash
# 動作テスト: 自動フォールバックを疑似的に再現してアラート一式を確認する。
# 手動の /model 切り替えは v1.3.0 から意図的に鳴らない仕様のため、
# 実際の音・通知はこのスクリプトで確認してください。
#
# 使い方（プラグインインストール後）:
#   bash ~/.claude/plugins/cache/kai-market/model-switch-alert/*/scripts/test-alert.sh
set -u
hook="$(cd "$(dirname "$0")" && pwd)/model-switch-alert.sh"
[ -f "$hook" ] || { echo "model-switch-alert.sh が見つかりません"; exit 1; }

dir=$(mktemp -d)
t="$dir/transcript.jsonl"
sid="test-alert-$$"
export CLAUDE_MODEL_ALERT_COOLDOWN=0
payload() { printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$t"; }

echo "1/3 ベースライン確立（Fable 5 のセッションを再現）"
printf '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}\n' > "$t"
payload | bash "$hook" > /dev/null

echo "2/3 自動フォールバックを再現 → ソナー音＋読み上げ＋通知が出ます"
printf '%s\n%s\n%s\n' \
  '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}' \
  '{"type":"user","message":{"content":"(automatic fallback simulation)"}}' \
  '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[]}}' > "$t"
payload | bash "$hook"
sleep 6

echo "3/3 復帰を再現 → ファンファーレが鳴ります"
printf '%s\n%s\n%s\n%s\n%s\n' \
  '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}' \
  '{"type":"user","message":{"content":"(automatic fallback simulation)"}}' \
  '{"type":"assistant","message":{"model":"claude-opus-4-8","content":[]}}' \
  '{"type":"user","message":{"content":"(recovery simulation)"}}' \
  '{"type":"assistant","message":{"model":"claude-fable-5","content":[]}}' > "$t"
payload | bash "$hook"
sleep 4

rm -rf "$dir" "${TMPDIR:-/tmp}/claude-model-alert-$sid"
echo "テスト完了。音と通知が確認できていれば正常に動作しています。"
echo "（実際のセッションでは、自分で /model を切り替えたときは鳴りません。"
echo "  痕跡なしにモデルが変わる自動フォールバックのときだけ鳴ります）"
