# cc-statusline

A Claude Code statusline that shows context window usage, cost breakdown, and session info in your terminal.

![cc-statusline](screenshot.png)

## Features

- **Context** -- progress bar with color thresholds (green < 50%, yellow 50-80%, red > 80%), percentage, and token count (e.g., 61k/1.0M)
- **Cost** -- per-category breakdown: cache reads, cache writes, output tokens in USD. Shows both calculated API total and Anthropic-reported session total
- **Info** -- model name (e.g., "Opus 4.6 (1M context)"), project name, working directory
- **Duration** -- session duration and Claude Code version

## Quick Install

```bash
git clone https://github.com/sirkhet-dev/cc-statusline.git
cd cc-statusline
./install.sh
```

## Manual Install

1. Download the script:

```bash
curl -fsSL https://raw.githubusercontent.com/sirkhet-dev/cc-statusline/main/slim/statusline.sh -o ~/.claude/statusline.sh
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

## Requirements

- `jq` -- JSON parsing
- `python3` -- cost calculation from transcript
- `bc` -- number formatting

```
apt:    sudo apt install jq python3 bc
brew:   brew install jq python3 bc
pacman: sudo pacman -S jq python bc
```

## Uninstall

```bash
./install.sh --uninstall
```

Restores your previous statusline configuration if one existed.

## How It Works

Claude Code pipes a JSON object to the script's stdin on each refresh cycle. The script parses session data with `jq`, calculates API costs by analyzing the transcript file with an embedded Python script (results cached for 5 seconds), and outputs formatted text with box-drawing characters to stdout.

## Customization

You can modify the following in `slim/statusline.sh`:

- **Colors** -- ANSI codes at the top of the script (lines 5-10)
- **Bar width** -- `W=72` variable
- **Pricing** -- `PRICING` dictionary in the embedded Python block

## Full Version

Coming soon -- git branch info, rate limits, and more.

## License

MIT
