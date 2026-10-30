# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.1.1] - 2026-10-29

Fixes for races between the app and the command line, settings that failed silently, and a few
hand-edited or unexpected files.

### Added

- The chat transfer also brings the missing parent chats of a sub-session, so it shows under its parent
  in the target account (a toggle in the transfer window, on by default).

### Fixed

- Pin sync and the transfer's pins now show in Claude's sidebar: 1.1.0 wrote a copy Claude ignores. The
  account you used last is the base: its pinned shared chats come first, in its order, then the opened
  account's own pins. A transfer puts the carried pins on top.
- The app and the command line no longer both start one account in the moment before its window
  appears; launch decisions are shared between them.
- An account the switcher is copying chats into cannot be opened or deleted until the copy finishes; it
  says it is being updated. Chat links and pin sync leave such an account alone too.
- Settings that cannot be saved now say so instead of failing silently, and two writers no longer lose
  each other's labels or options.
- When several accounts wait for a browser sign-in at once, each sign-in goes to the right one
  (the frontmost, else the most recently opened).
- Chat transfer no longer stalls the panel.
- A `claude_desktop_config.json` with an unexpected shape is left untouched instead of having its
  preferences replaced.
- Open accounts are recognised however their folder path is spelled.
- A hand-edited negative colour no longer crashes the app, and hand-edited labels can no longer place
  a launcher outside `~/Applications`.
- `--claude-path` accepts only Claude.
- A failed change of the `claude://` handler is reported, and `--revert` exits 1 when something could
  not be undone.
- The account row's tooltip shows both the open action and the usage detail again; the weekly limit
  was hidden.
- Quitting an account is detected even if macOS reuses its process id.
- `--launch` with sign-in routing on stops waiting about 3 seconds after the handler is back, instead
  of always 20, and says why it waits.

### Changed

- `brew uninstall --zap` also removes the switcher's backups of `claude_desktop_config.json`.
- Release builds must be universal: they fail instead of quietly building for one architecture.
- New log and lock files are private to your user (0600).

## [1.1.0] - 2026-10-29

Chats that exist in several accounts are now visible, and the switcher can keep their pins and,
optionally, their worktrees and history in step.

### Added

- Shared chats: the switcher finds chats that exist in several accounts and shows, per account,
  whether a copy is up to date, behind, forked, missing its history file, or would split into a
  separate copy when continued there.
- A note in the panel when chats differ between accounts, with a **Show** button; the cross hides it
  until the set of differing chats changes.
- A Shared chats window with one status per account and **Open where it's up to date**.
- `--shared-chats` on the command line prints the same list.
- Experimental, off by default: **Keep worktree chats linked across accounts**, so both accounts use
  one worktree and one history instead of two copies. In the Shared chats window, **Sync** (a copy that
  is behind or forked), **Link** (a chat that would split), **Link all** (also under the setting in
  the panel; it asks first) and **Unlink**. Tried with Claude 4.29; the panel says so when your
  Claude is another version.
  - Every file of Claude's that it changes is backed up first. An out-of-date history is moved to the
    switcher's backups, never deleted, and only when no other account's copy still uses that file;
    otherwise it stays and the result carries a warning.
  - Each link run keeps a copy of every changed account's `git-worktrees.json` in
    `backups/transcripts/<time>/<account>/`, never rotated.
  - Sync and Link check the chat again right before they write and refuse with "This chat changed
    since it was checked; refresh and try again." if it moved on. A copy picked to replace in a fork
    is refused if it changed since the scan.
  - Accounts that are open, or still starting, are never written to; the switcher offers to quit and
    reopen them.
  - The switcher keeps a ledger (`links.json`) of what it changed, so Unlink removes exactly that.
- A transfer links worktree chats while linking is on: chats copied now, and chats already there with
  the same history. Chats already there but behind or forked are not linked (use Sync), and a busy link
  job makes the transfer report them as "not linked".
- `--unlink-chats` removes every link the switcher made. Open and starting accounts are skipped; it
  exits 0 even then, and 1 only if the ledger cannot be read.
- A check that linked chats are still linked: if Claude moved one again, linking turns itself off and
  nothing is unlinked.
- A warning when a linked chat is open in two accounts at once. It relies on chat processes started
  with `--resume`, so a chat started in the last minutes may not be detected.
- Pin sync, on by default (**Sync pins across accounts**, `SyncPins` in `settings.json`): when the
  switcher opens a closed account, the pins of the chats it shares with the account you used last
  follow that account, in the same order. Pins of chats only the opened account has are kept after
  them, and a chat unpinned there is unpinned here. The starred flag on the chat records follows the
  list, a run that stopped halfway is repaired the next time pins sync into that account, and nothing is written when nothing
  changes. Backups come first; a failure is logged as a fixed reason without chat names or paths and
  never stops the account from opening. Opening Claude.app directly skips it.

### Changed

- With linking off, the transfer asks you to confirm before copying a chat that uses a git worktree,
  since Claude continues it as a separate copy in the other account. With linking on, it links the
  chat instead.
- An account that is still starting counts as open for the transfer, for linking and unlinking, and
  for pin sync.

### Fixed

- The transfer no longer reports "already there" for a copy that is behind or forked; it says how far
  behind, or that it has diverged.

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

[1.1.1]: https://github.com/onlyilkr/claude-profile-switcher/releases/tag/v1.1.1
[1.1.0]: https://github.com/onlyilkr/claude-profile-switcher/releases/tag/v1.1.0
[1.0.0]: https://github.com/onlyilkr/claude-profile-switcher/releases/tag/v1.0.0
