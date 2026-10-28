# Contributing

Thanks for taking an interest. Contributions of any size are welcome, typo fixes and bug reports
included. Please read the [Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/)
spirit before joining a discussion: be kind and assume good faith.

## The most useful thing you can contribute

Reports from setups that have not been tried yet: Intel Macs, macOS 13 and 14, Claude installed
somewhere other than `/Applications`, enterprise (managed) Claude installs, and the sign-in routing
with Google and email links on accounts in different organisations. Open an issue with what you tried
and what happened, using the bug report template even if nothing went wrong.

## Getting set up

You need macOS 13 or later and Xcode (or a Swift 5.9+ toolchain). There are no dependencies.

```sh
git clone https://github.com/onlyilkr/claude-profile-switcher.git
cd claude-profile-switcher
make check      # unit tests, release build of the app, command line smoke test
make install    # builds and copies the app to ~/Applications, then opens it
```

| Target | Does |
| --- | --- |
| `make build` / `make test` | `swift build` / `swift test` |
| `make app` | `build/Claude Profile Switcher.app`, universal, ad-hoc signed |
| `make install` | The app into `~/Applications`, replacing a running copy |
| `make dist VERSION=1.2.3` | Release zip, checksums, cask and notes in `dist/`, nothing published |
| `make preview` | README screenshots of the panel from sample accounts |

## Code layout

| Path | What lives there |
| --- | --- |
| `Sources/SwitcherCore` | Everything testable: profiles, process detection, launching, sign-in routing, chat transfer, shared chats and linking (`SharedChats/`), pins and pin sync, usage, icons, launchers |
| `Sources/ClaudeProfileSwitcher` | The menu bar app (`AppDelegate`, `Panel/`) and the command line (`CLI.swift`), one binary |
| `Tests/SwitcherCoreTests` | Unit tests; they only ever use temporary folders |
| `scripts/` | Building, packaging and publishing |
| `packaging/` | The Homebrew cask template |

## Testing without touching your real accounts

Unit tests never read your data. For a manual run against a real Claude, point the switcher at a
throwaway home with the hidden `--home` flag. Profiles, settings and logs go there; Claude itself and
Launch Services are still the real ones.

```sh
CPS="build/Claude Profile Switcher.app/Contents/MacOS/ClaudeProfileSwitcher"
H=$(mktemp -d); mkdir -p "$H/Library/Application Support/Claude"
"$CPS" --home "$H" --add-account       # opens a real Claude window at a sign-in screen
"$CPS" --home "$H" --list
"$CPS" --home "$H" --launch "Account 2"  # must bring it forward, not start a second copy
```

Quit the test Claude windows when done, and delete `$H`. `--home` moves files, not Launch Services:
`--route-sign-ins` and `--revert` change the real `claude://` handler even with `--home`, so leave
them out of throwaway runs unless you mean to change it.

For the panel, `make preview` renders it with sample accounts in light and dark mode, which is the
quickest way to review a layout change.

## Traps worth knowing about

These have already shaped the code; please read them before changing launching or links.

**Claude takes no single instance lock on macOS.** On Windows, Electron refuses a second copy on the
same data folder. On macOS, Claude relies on Launch Services instead, which knows nothing about
`--user-data-dir`. Two copies on one folder both start and corrupt it, so the switcher has to know
exactly which folders are open (`ProcessScanner`, from `KERN_PROCARGS2`) before every launch. Never
launch without checking.

**Launch Services sees one app, not one per account.** Every copy of Claude has the same bundle id, so
anything addressed by bundle id or name (AppleScript `tell application`, `open -a`, `NSWorkspace` without
`createsNewApplicationInstance`) may reach any of them. Address a copy by pid.

**Links arrive as Apple Events, not arguments.** Claude handles `claude://` through `open-url`, so a link
on the command line is ignored. An open copy gets a `GURL` event sent to its pid; a new copy gets the
link through `NSWorkspace.open(_:withApplicationAt:configuration:)`.

**Claude takes the `claude://` handler back every time it starts.** That is why routing needs the menu
bar app running.

**Claude writes its chat list and pins back when it quits.** Anything copied into a running copy's
store or `claude_desktop_config.json` is lost, so the transfer quits the target first.

**An account that is still starting is open.** A launch is not visible as a process for a few seconds, so
anything that writes to an account's files (transfer, link, unlink, pin sync) must use
`Switcher.openFolders()`, which includes accounts the switcher has just started, and check again right
before writing. The check can run off the main thread, which is why the list is behind a lock.

**Linked chats share one history file.** Never move or edit a transcript while any Claude Code process
runs that chat (`ProcessScanner.liveCLISessions()`, which needs `--resume` in its arguments), and move a
replaced history to `backups/transcripts/` only when no other copy still uses it.

**macOS 14 only lets the active app hand focus on.** The switcher activates itself, then yields to
Claude. A copy whose window was closed needs the Dock click's reopen event (`rapp`).

**Automation permission follows the code signature.** Ad-hoc builds get a new signature on every
rebuild, so macOS asks again after each one. That is expected while developing.

## Style

Match what is already there. Comments explain why, not what, and say so when code works around a
Claude or macOS quirk, because the next person will otherwise remove it. Every user-facing string goes
through `L("English", "Türkçe")`.

## Reporting bugs

Use the bug report template. It asks for `claude-profiles --status` and `--list`; both print paths
with your user name and your profile names, so replace those before pasting. Neither prints a sign-in
link or a token.

## Releasing

1. Add the version's section to `CHANGELOG.md` on `main`.
2. Tag a commit on `main` and push it: `git tag v1.2.3 && git push origin v1.2.3`.
3. The release workflow checks that the tag is on `main`, runs the tests, builds the universal app and
   publishes the zip, `checksums.txt` and the cask to the GitHub release. A separate job then sends the
   cask to the tap; only that job has the tap token.
4. A tag with a suffix (`v1.3.0-rc.1`) becomes a GitHub prerelease and never reaches the tap. The tap only
   moves forward: an older tag pushed later is refused.

Repository settings that the workflow relies on: a `release` environment limited to `v*` tags (with
required reviewers if you want a second pair of eyes), `HOMEBREW_TAP_TOKEN` stored as a secret of that
environment (a fine-grained token with contents read/write on the tap only), a tag ruleset that lets only
maintainers create `v*` tags, and private vulnerability reporting turned on.

## Signing and notarization

Releases are ad-hoc signed, and the Homebrew cask clears the quarantine flag. Notarizing would
remove that step, but it needs a Developer ID certificate and the hardened runtime, and the hardened
runtime blocks Apple Events unless the app carries the `com.apple.security.automation.apple-events`
entitlement. Without it every focus and link hand-off fails with error -1743, which looks exactly like
the user refusing Automation permission. Add the entitlement before turning notarization on.
