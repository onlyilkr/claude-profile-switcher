# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub Security Advisories:
[Report a vulnerability](https://github.com/onlyilkr/claude-profile-switcher/security/advisories/new).
Do not open a public issue or pull request for a security problem.

Include the version (`claude-profiles --version`), your macOS and Claude Desktop versions, what you did
and what happened. Redact personal data: your macOS user name, account and profile names, email
addresses, UUIDs and chat titles. You can expect an acknowledgement within a few days; this is a small
volunteer project, so there is no formal SLA.

## What the app touches

Knowing this helps judge whether something is in scope:

| Where | What | How |
| --- | --- | --- |
| `~/Library/Application Support/ClaudeProfile-<name>` | Extra profiles | Created empty; moved to the Trash on delete, only while that account's Claude is closed |
| `~/Library/Application Support/Claude` | Your original account | Read; written only by a chat transfer into it, as below |
| A profile's `claude-code-sessions/…` | Chat records | Written only by a transfer, as new files (`link(2)`, never replacing one) |
| A profile's `claude_desktop_config.json` | Pin list | Only the pin list, only by a transfer, or when the switcher opens that account with pin sync on; only while that Claude is closed (an account that is still starting counts as open), after a backup |
| A profile's `config.json`, `plan-usage-history.json` | Signed-in state, usage | Read: the signed-in flag, the last account id, the token cache's length (the token itself is never used, kept or sent), usage percentages |
| `~/.claude/projects/…/<id>.jsonl` | Chat history | Read, to compare the copies of a shared chat (message counts only). With linking turned on, Sync and Link move the out-of-date copy to the switcher's `backups/transcripts/`, unless another account's copy still uses that file, in which case it stays; history is never deleted or edited |
| A profile's `git-worktrees.json` | Worktree list | Only with linking turned on, only while that account's Claude is closed, after a backup; an entry added, and any entries leased to that chat released (Link can release several), other fields kept; the file is also copied, never rotated, to `backups/transcripts/<time>/<account>/` in each link run. Never created if missing, never written if its format is unfamiliar |
| A profile's chat record (`local_<id>.json`), `isStarred` | Pinned flag | Rewritten when the switcher opens that account with pin sync on (the default), for chats the account shares with the account used last whose pin state differs (also repairing a run that stopped halfway); only while that account is closed, after a backup, other fields kept; a failure is logged as a fixed reason without chat names or paths and never blocks opening the account |
| A profile's chat record (`local_<id>.json`) | Chat record | Replaced only by Sync, Link and Link all (one operation), after a backup, only while the chat is unchanged since it was checked and no account involved is open or starting, and not for a chat already on the same folder with the lease held. The copy keeps its archived and starred state; the pin list is not touched |
| `~/Library/Application Support/Claude Profile Switcher/links.json` | Link ledger | The switcher's own list of what it wrote, so Unlink can undo exactly that |
| `~/Applications/Claude - <name>.app` | Launchers | Created and removed only if they carry the switcher's marker |
| Launch Services | `claude://` handler | Changed only while sign-in routing is on; given back when it is turned off |
| `~/Library/Application Support/Claude Profile Switcher` | Settings, logs | The switcher's own files |

The app makes no network requests.

## Scope

In scope:

- Anything that writes, overwrites or deletes something it should not: Claude's own data folder
  (other than a chat transfer into it), a profile that is open, a file outside a profile folder, an existing chat record, keys in
  `claude_desktop_config.json` other than the pin list.
- Starting a second Claude on a data folder that already has one.
- A `claude://` or `claudeprofileswitcher://` link that makes the switcher do more than open an existing
  profile or hand the link to Claude: creating, renaming or deleting profiles, running commands,
  reaching a profile other than the one chosen by the routing rules.
- Path traversal or shell injection through profile names, launcher bundles or links.
- Leaking secrets: a sign-in link, token, cookie or chat content written to a log, the panel, the
  command line output or the network.
- Supply-chain issues in the release pipeline (unpinned actions, tampered checksums or cask).

Out of scope: bugs that need an attacker who already controls your user account, and changes in Claude
Desktop's undocumented behaviour that make a feature stop working without damaging anything (file a
normal bug report).

## Supported versions

Only the latest release receives fixes.
