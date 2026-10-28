# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-28

### Added

- Shared chats: the switcher finds chats that exist in several accounts and shows whether a copy is
  up to date, behind, forked or missing its history.
- A note in the panel when chats differ between accounts, with a Show button.
- A Shared chats window with one status per account and **Open where it's up to date**.
- `--shared-chats` on the command line.
- Experimental, off by default: **Keep worktree chats linked across accounts**, so both accounts use
  one worktree and one history. **Sync**, **Link**, **Link all** and **Unlink** in the Shared chats
  window; a transfer links worktree chats when it is on. Tried with Claude 4.29. Every file it changes
  is backed up first, and replaced history is moved to the switcher's backups, never deleted.
- `--unlink-chats` removes every link the switcher made (open accounts are skipped).
- A check that linked chats are still linked; if Claude moved one again, linking turns itself off.
- A warning when a linked chat is open in two accounts at once.

### Fixed

- The chat transfer no longer says "already there" for a copy that is behind or forked; it says how
  far behind.
- The transfer warns before moving a chat that uses a git worktree, which Claude continues as a
  separate copy in the other account.

## [1.0.0] - 2026-10-28

First public release: a macOS port of
[Claude-Code-Desktop-Switcher](https://github.com/PriyanshuGeTRekT/Claude-Code-Desktop-Switcher)
(Windows), rebuilt as a native menu bar app.

### Added

- Menu bar panel listing every Claude desktop account, with a ring that shows whether each is open,
  waiting for a sign-in or starting. Click to open an account or bring it forward.
- Add account: a fresh profile that opens Claude at its sign-in screen.
- Rename in place (the label only) and move a profile to the Trash, confirmed in place.
- Running detection from each Claude process's real arguments, so a profile that is already open is
  brought forward instead of started twice. Claude takes no single instance lock on macOS, so this is
  what keeps two copies off one data folder.
- Usage meter: each account's 5-hour limit as Claude last measured it and how long ago, from the
  profile's own `plan-usage-history.json`, with the weekly limit in its tooltip. No credentials are
  read. When Claude stops measuring an open account, its row shows –% and a note in the panel says
  how to get it measuring again. **Open usage in Claude** shows the live numbers and reset times in
  that account's Claude.
- Logo (`docs/images/logo.svg`), the matching app icon and a template menu bar icon.
- Optional sign-in routing: the switcher becomes the `claude://` handler and passes each browser
  sign-in to the account that asked for it; other links go to Default or a chosen account. Claude takes
  the handler back whenever it starts, and the switcher takes it again within seconds.
- Claude Code chat transfer between accounts with the rules of
  [claude-migrate](https://github.com/onlyilkr/claude-migrate): ids kept, `bridgeSessionIds` emptied,
  `scheduledTaskId` removed, nothing overwritten, chats deleted in the target never revived, never while
  the target account is open. Pinned chats stay pinned, in the source's order.
- Launcher apps in `~/Applications` with a coloured badge, for Spotlight, Launchpad and the Dock.
- Per-account environment variables (`ProfileEnv`) and launch flags (`ProfileArgs`).
- Open at login.
- Command line in the same binary: `--list`, `--launch`, `--add-account`, `--shortcut`, `--status`,
  `--route-sign-ins`, `--revert`, `--open-link`, `--open-links-in`, `--claude-path`.
- English and Turkish, following the system language.

[1.1.0]: https://github.com/onlyilkr/claude-profile-switcher/releases/tag/v1.1.0
[1.0.0]: https://github.com/onlyilkr/claude-profile-switcher/releases/tag/v1.0.0
