# lua-browser skill — setup

## 1. Install the skill

In Lua open **Settings → General → Developer**, then choose **Install the
lua-browser skill** for Claude Code, Codex, or OpenClaw. Lua links its bundled
skill into the selected agent's `skills/lua-browser` directory, so the skill
stays current with app updates.

From a source checkout, link it manually instead:

```bash
ln -sfn "$PWD/tools/claude-skill/lua-browser" ~/.claude/skills/lua-browser
```

Node 22 or newer is required. The skill has no npm dependencies.

## 2. Enable Lua's CDP endpoint

The endpoint is off by default. Enable it for the app you run, then relaunch:

```bash
# Release
defaults write dev.jow.LuaBrowser PhiRemoteDebuggingPort -int 0
# Local development build
defaults write dev.jow.LuaBrowser.Development PhiRemoteDebuggingPort -int 0
```

`0` selects an ephemeral port. A fixed port such as `9333` also works. To
disable access, run `defaults delete <bundle-id> PhiRemoteDebuggingPort`.

The endpoint listens on `127.0.0.1`, but any local process can control the
browser while it is enabled. Leave it off when it is not needed.

## 3. Verify

Lua's first compatibility releases retain the existing Chromium profile at
`~/Library/Application Support/com.ojowwalker77.PhiBrowser`. After relaunch:

```bash
cat ~/Library/Application\ Support/com.ojowwalker77.PhiBrowser/DevToolsActivePort
node ~/.claude/skills/lua-browser/scripts/runner.mjs <<'EOF'
const task = await ensureAgentSpace('smoke test')
cliLog(task)
await openTab('https://example.com')
cliLog(await pageInfo())
EOF
```

For a complete skill-development pass:

```bash
node ~/.claude/skills/lua-browser/scripts/selftest.mjs
```

## Troubleshooting

- **DevToolsActivePort not found:** enable the default for the bundle ID that
  is actually running, then relaunch. `PHI_USER_DATA_DIR` can override profile
  discovery for compatibility testing.
- **Endpoint not responding:** the port file may be stale after a crash;
  relaunch Lua.
- **No app connection available:** open a Lua window and retry. The
  `PhiAgentSpace` protocol name is part of the embedded framework ABI and is
  intentionally retained.
- **PhiAgentSpace.sendMessage unknown method:** the installed Phi Framework
  predates the required ABI. Install the pinned framework version documented
  in the repository, then rebuild Lua.
