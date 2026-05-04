# cc-statusline

> Claude Code statusline -- context, cost, git, rate limits, and more in your terminal.

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square)](./LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Claude Code](https://img.shields.io/badge/Claude_Code-statusline-cc785c?style=flat-square)](https://code.claude.com/docs/en/statusline)

![cc-statusline](screenshot.png)

---

## Table of Contents

- [Features](#features)
- [Quick Install](#quick-install)
- [Manual Install](#manual-install)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Customization](#customization)
- [Uninstall](#uninstall)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Context** -- progress bar with color thresholds (green < 50%, yellow 50-80%, red > 80%), percentage, and token count (e.g., 61k/1.0M)
- **Cost** -- per-category breakdown: cache reads, cache writes, output tokens in USD. Shows both calculated API total and Anthropic-reported session total
- **Git** -- branch name with dirty indicator (`main*`)
- **Effort Level** -- current reasoning effort with visual icon (low / medium / high / xhigh / max)
- **Rate Limits** -- 5-hour and 7-day usage bars with reset times (Pro/Max/Team)
- **Token Speed** -- output tokens per second
- **Tool Tracking** -- currently running and recently completed tools
- **Agent Tracking** -- running subagents with type and model
- **Todo Progress** -- task completion count and current task name
- **Session Info** -- model name, project/directory, duration, CC version, session name

---

## Quick Install

```bash
git clone https://github.com/efecanbasoz/cc-statusline.git
cd cc-statusline
./install.sh
```

---

## Manual Install

1. Download the script:

```bash
curl -fsSL https://raw.githubusercontent.com/efecanbasoz/cc-statusline/main/statusline.sh -o ~/.claude/statusline.sh
```

2. Make it executable:

```bash
chmod +x ~/.claude/statusline.sh
```

3. Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

> If `settings.json` already exists, merge the `statusLine` key into your existing config.

---

## Requirements

- `jq` -- JSON parsing
- `python3` -- cost calculation from transcript
- `bc` -- number formatting
- `git` -- branch info (optional, for git display)

```
apt:    sudo apt install jq python3 bc git
brew:   brew install jq python3 bc git
pacman: sudo pacman -S jq python bc git
```

---

## Configuration

Toggle features with environment variables. Set in `~/.bashrc`, `~/.zshrc`, or your shell profile:

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_SHOW_GIT` | `1` | Git branch + dirty state |
| `CC_SHOW_EFFORT` | `1` | Effort level indicator |
| `CC_SHOW_USAGE` | `1` | Rate limit bars |
| `CC_SHOW_SPEED` | `0` | Output token speed |
| `CC_SHOW_TOOLS` | `0` | Tool activity line |
| `CC_SHOW_AGENTS` | `0` | Agent tracking line |
| `CC_SHOW_TODOS` | `0` | Todo progress line |
| `CC_SHOW_SESSION` | `0` | Session name display |

Example:
```bash
export CC_SHOW_TOOLS=1 CC_SHOW_AGENTS=1 CC_SHOW_TODOS=1
```

Set `0` to disable, any other value to enable.

---

## How It Works

Claude Code pipes a JSON object to the script's stdin on each refresh cycle. The script parses session data (model, context window, costs, rate limits, etc.) with `jq`, calculates per-model API costs by analyzing the transcript file with an embedded Python script (results cached for 5 seconds), and outputs formatted text to stdout.

---

## Customization

You can modify the following in `statusline.sh`:

- **Colors** -- ANSI codes at the top of the script
- **Bar width** -- `W=72` variable
- **Pricing** -- `PRICING` dictionary in the embedded Python block

### Known Limitations

- **Rate limits** appear only for Claude.ai subscribers (Pro/Max/Team) after the first API response in the session.
- **Tool/Agent/Todo tracking** only shows data when Claude is actively using tools, dispatching agents, or managing tasks. Enable with `CC_SHOW_TOOLS=1 CC_SHOW_AGENTS=1 CC_SHOW_TODOS=1`.
- **Effort level** reflects the live session value including mid-session `/effort` changes. Absent when the current model does not support the effort parameter.

---

## Uninstall

```bash
./install.sh --uninstall
```

Restores your previous statusline configuration if one existed.

---

## Contributing

Contributions are welcome! Please open an issue first to discuss what you'd like to change.

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Test with your Claude Code setup
4. Commit your changes
5. Push to the branch and open a Pull Request

---

## License

[Apache-2.0](./LICENSE)
