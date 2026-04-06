---
name: account-add
description: Add a Claude Code account to the multi-account registry. Use when the user wants to register a new account.
user-invocable: true
allowed-tools: Bash
argument-hint: [account-name]
---

# Account Add

Run `python3 ${CLAUDE_PLUGIN_ROOT}/src/tools/accounts.py add $ARGUMENTS` and report the result.

Required args: `<name> --config-dir <path> --color <color>`
Optional: `--display-name <name>` `--monthly-limit <amount>` `--link-to <account>`
Valid colors: blue, green, orange, red, purple, yellow

`--link-to` symlinks `plugins/` and `settings.json` from the new account to the specified account, so they share plugin installations and config.

Example: `account-add work --config-dir ~/.claude-work --color red --link-to personal`
