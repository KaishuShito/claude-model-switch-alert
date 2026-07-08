# model-switch-alert

Claude Code のモデルが静かに切り替わったことを、サウンドで知らせるプラグインです。

Fable 5 には、安全分類器がリクエストをフラグすると Opus 4.8 へ自動的に切り替わる仕組みがあります（[Redeploying Fable 5](https://www.anthropic.com/news/redeploying-fable-5)）。切り替えはセッションの途中で静かに起きるため、気づかないまま別のモデルで作業を続けてしまうことがあります。このプラグインはツール使用後と毎ターン終了時に実際の応答モデルを確認し、期待するモデルと違っていればすぐに知らせます。

## アラートの段階設計（鳴り続けない）

| 状況 | 音 | 追加の動作 |
|------|-----|-----------|
| 切り替わった瞬間 | 🛥 Submarine（ソナー音） | 音声読み上げ + アプリ内表示または通知センター |
| 切り替わったまま | 📡 Morse(短いビープ、毎ターン) | 画面に警告表示 |
| 元のモデルに復帰 | 🎺 Hero（ファンファーレ） | 音声読み上げ |

音はすべて macOS 標準のシステムサウンド（`/System/Library/Sounds`）なので、どの Mac でも追加セットアップなしで動きます。鳴り続けるアラームは意図的に避け、切り替わったままの間は毎ターン短いビープで知らせ続ける設計にしています。

## 仕組み

Claude Code の hook は標準入力の JSON に現在のモデル ID を含みません。そこで Stop / PostToolUse hook がセッションのトランスクリプト（JSONL）を読み、最新のアシスタントメッセージの `.message.model` を取り出します。セッションごとの状態ファイルで「切り替わった瞬間 / 継続中 / 復帰」を判定します。

PostToolUse ではモデルが変化したタイミングだけ通知します。切り替わったままの状態でツールが何度も呼ばれても、ツールごとのビープや systemMessage は出ません。従来どおり Stop ではターン終了時の継続中ビープが動きます。

サブエージェント（sidechain）の応答は判定から除外しています。Haiku などで動く探索用サブエージェントを誤って「切り替え」と検知することはありません。

## 手動切り替えは通知しない

Fable と Opus を使い分けている場合でも、自分で `/model` を切り替えたときには鳴りません。手動切り替えはトランスクリプトに `Set model to ...` というコマンド出力の痕跡を残すため、これが見つかったときはアラートを出さず、期待モデル（ベースライン）を新しい選択に追従させます。痕跡なしにモデルだけが変わったとき、つまり自動フォールバックのときだけ通知します。

## 並列セッションでも鳴り響かない

多数のセッションを並列で走らせている場合（例: AGI Cockpit で 100 タスク）、そのうち複数が同時に切り替わると、素朴な実装ではアラートが連発します。これを避けるため、音と通知にはマシン全体で共有するクールダウン（デフォルト 30 秒）を設けています。最初の 1 件だけが音を鳴らし、残りは画面表示のみになります。

```bash
export CLAUDE_MODEL_ALERT_COOLDOWN=60   # 秒。0 で無効化
```

## AGI Cockpit 連携

[AGI Cockpit](https://agi-labo.com/tools/cockpit?utm_source=github&utm_medium=readme&utm_campaign=model-switch-alert-202607&utm_content=cockpit-section) を使っている場合、切り替えアラートは `cockpit display --text` 経由で **Cockpit アプリ内の最前面表示** として出ます（非ブロッキング）。Cockpit がない環境では macOS の通知センターへフォールバックし、Cockpit の存在を一度だけ一行で案内します（音なし・ポップアップなし・二度目はありません）。

通知タイトルには、AGI Cockpit のタスク名が分かる場合はそのタスク名、分からない場合は作業フォルダ名が入ります。通知本文にもフルパスが付きます。

## statusLine 連携（手動オプトイン）

Claude Code の statusLine はプラグインから自動登録できないため、使っている statusLine スクリプトから手動で呼び出してください。statusLine の標準入力 JSON には `model.id` が含まれるので、長いターン中でもより早く変化を検知できます。

呼び出し元が stdin を再利用できるよう、先に JSON を変数へ読み込んでから渡します。

```bash
status_json=$(cat); bash "$HOME/.claude/plugins/cache/kai-market/model-switch-alert"/*/scripts/statusline-model-watch.sh "$status_json"
```

この watcher は stdout に何も出さず、モデル変化時だけバックグラウンドで通常のアラート処理を起動します。元の statusLine 表示は、その後に同じ `status_json` から組み立ててください。

## 動作要件

- macOS（`afplay`、`say`、`osascript` を使用）
- `jq`

## インストール

### 1. マーケットプレイスを追加

```
/plugin marketplace add KaishuShito/claude-model-switch-alert
```

### 2. プラグインをインストール

```
/plugin install model-switch-alert@kai-market
```

### 3. Claude Code を再起動

## 動作テスト

自分で `/model` を切り替えても鳴りません（手動切り替えは仕様としてスキップします）。実際の音・通知は同梱のテストスクリプトで確認できます。

```bash
bash ~/.claude/plugins/cache/kai-market/model-switch-alert/*/scripts/test-alert.sh
```

自動フォールバック、PostToolUse、statusLine、手動切り替えスキップを疑似的に検査します。

## 設定

期待するモデル（ベースライン）は、デフォルトでは**セッション開始時のモデル**になり、以降は手動の `/model` 切り替えに追従します。モデル設定に関わらずそのまま使えます。

セッション開始時点の期待モデルを明示したい場合は、環境変数で指定できます。

```bash
export CLAUDE_EXPECTED_MODEL="claude-fable-5"
```

この値で始まるモデル ID が初期ベースラインになります（手動切り替え時はこの場合も追従します）。

## アンインストール

```
/plugin uninstall model-switch-alert@kai-market
```

## English

Sound alerts for Claude Code when your model silently switches. Fable 5 can fall back to Opus 4.8 when a safety classifier flags a request. `Stop` and `PostToolUse` hooks read `.message.model` from the session transcript (hook stdin has no model field) and play staged alerts: Submarine sonar + voice + notification on switch, a Morse beep every turn while switched at turn end, and a Hero fanfare on recovery. `PostToolUse` only alerts on transitions, so tool calls do not beep repeatedly while the switched model is ongoing.

Notifications include context: the AGI Cockpit task name when available, otherwise the folder name, plus the full working directory in the body. Manual `/model` switches leave a "Set model to" trace in the transcript, so they are skipped silently and the expected baseline follows your choice — only automatic fallbacks alert. All sounds ship with macOS. Works with [AGI Cockpit](https://agi-labo.com/tools/cockpit?utm_source=github&utm_medium=readme&utm_campaign=model-switch-alert-202607&utm_content=cockpit-section) for in-app frontmost displays. Set `CLAUDE_EXPECTED_MODEL` to pin a strict initial baseline.

Optional statusLine integration is manual because plugins cannot register statusLine scripts automatically. If your statusLine script already reads stdin into a variable, call:

```bash
bash "$HOME/.claude/plugins/cache/kai-market/model-switch-alert"/*/scripts/statusline-model-watch.sh "$status_json"
```

The watcher prints nothing and starts the normal alert path in the background only when `model.id` changes.

## License

MIT
