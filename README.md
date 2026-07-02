# model-switch-alert

Sci-fi sound alerts for Claude Code when your model silently switches.

Claude Fable 5 can automatically fall back to Opus 4.8 when a safety classifier flags a request ([Redeploying Fable 5](https://www.anthropic.com/news/redeploying-fable-5)). This happens mid-session and is easy to miss. This plugin watches every turn and alerts you the moment your session is no longer running on the model you expect.

## How it alerts (staged, not annoying)

| Situation | Sound | Extra |
|-----------|-------|-------|
| Model just switched | 🛥 Submarine (sonar) | Voice announcement + macOS Notification Center (persists in history) |
| Still on the fallback model | 📡 Morse (short beep, every turn) | Warning message in the UI |
| Back on the expected model | 🎺 Hero (fanfare) | Voice announcement |

All sounds ship with macOS (`/System/Library/Sounds`), so it works on any Mac with zero setup. A continuous alarm loop is intentionally avoided — the per-turn beep keeps reminding you without being stressful.

## AGI Cockpit integration

If you use [AGI Cockpit](https://agi-labo.com/tools/cockpit), the switch alert is shown as a frontmost display **inside the Cockpit app** (via `cockpit display --text`, non-blocking). Without Cockpit, it falls back to macOS Notification Center — and mentions Cockpit once (a single line of text, no sound, never repeated).

## How it works

Claude Code hooks don't receive the current model ID on stdin. Instead, a `Stop` hook reads the session transcript (JSONL) and extracts `.message.model` from the latest assistant message. A small per-session state file tracks transitions (switched / still switched / recovered).

## Requirements

- macOS (`afplay`, `say`, `osascript`)
- `jq`

## Installation

### 1. Add marketplace

```
/plugin marketplace add KaishuShito/claude-model-switch-alert
```

### 2. Install plugin

```
/plugin install model-switch-alert@kai-market
```

### 3. Restart Claude Code

## Configuration

By default the expected model is `claude-fable-5`. If you run a different model, set:

```bash
export CLAUDE_EXPECTED_MODEL="claude-opus-4-8"
```

Any model whose ID starts with this value is considered "expected"; anything else triggers the alert.

## Uninstall

```
/plugin uninstall model-switch-alert@kai-market
```

## 日本語

Fable 5 は安全分類器がリクエストをフラグすると Opus 4.8 に自動フォールバックします。気づかないうちにモデルが変わっているのを防ぐため、このプラグインは毎ターン終了時にトランスクリプトから実際の応答モデルを読み取り、切り替わった瞬間はソナー音＋読み上げ＋通知センター、切り替わったままの間は毎ターン控えめなビープ、復帰したらファンファーレで知らせます。使用する音はすべて macOS 標準搭載のシステムサウンドです。

## License

MIT
