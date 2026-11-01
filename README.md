# Session Mover

A macOS companion to Claude Profiles (by MadAppGang) that shows every Claude Code session from every copy of the Claude desktop app and every account on your Mac in one window, and moves a session from one copy or account to another by drag and drop.

Claude shows a Claude Code session only in the app copy and account it was created in. When a copy switches accounts, for example after a usage limit, its sessions vanish from the sidebar. Session Mover finds them and moves them where you need them, keeping title, history, working folder, worktree, branch and PR links.

> **Unofficial.** Not affiliated with or endorsed by Anthropic or MadAppGang. It reads and writes the Claude desktop app's internal, undocumented files. Every move is backed up and can be undone, but use it at your own risk.

## What it does

- **Browse.** Every copy, account, organization and session, with search, filters and state chips (running, busy, usage limit, folder missing, archived, PRs). *Hidden in Their App* lists sessions in accounts their copy isn't signed in to.
- **Move.** Drag a session onto another copy or account. Preflight checks block unsafe moves (busy session, duplicate, unverified Claude version); *Quit & Move* quits both copies normally, moves the entry with its worktree lease and sidebar group, verifies, and reopens them.
- **Undo and History.** Every move is journaled with a byte-for-byte backup. ⌘Z or History ▸ Restore puts every file back. An interrupted move is finished or rolled back at next launch.
- **Open a Copy.** Uses Claude's own `claude://resume` link to open a session in another copy without quitting anything.

## Safety

- Never reads or writes conversation history (`~/.claude/projects`) or OAuth tokens. From a copy's `config.json` it reads only `lastKnownAccountUuid`.
- Moves only touch copies you allow in Settings ▸ Moves (default: `test1`, `test2`, i.e. throwaway copies). `SM_ALLOW=slug,slug` or `SM_ALLOW=all` overrides.
- Full moves only on Claude versions it has verified ([verified-versions.json](Sources/SessionMoverKit/Resources/verified-versions.json)); other versions get *Open a Copy* only. `smctl formatguard` shows which copies are verified.
- Never force-quits an app.

## Build, run, test

Needs Xcode 26 / Swift 6 on macOS 14+. Everything is a SwiftPM package; there is no Xcode project.

```sh
swift build                # library, smctl, app
swift test                 # SessionMoverKit unit tests against fixture trees in a temp dir
swift run smctl list       # every copy -> account -> org, with session counts and state chips (--json, --counts)
swift run smctl check      # cross-checks counts and running chips; exits 1 on mismatch
swift run smctl move <local_id> --to <slug>[/<account>[/<org>]] [--quit] [--dry-run]
swift run smctl history    # past moves; smctl undo <move id>; smctl recover
scripts/build-app.sh       # release build -> build/SessionMover.app, ad-hoc signed
open build/SessionMover.app
```

Signed, notarized releases: see [docs/RELEASE.md](docs/RELEASE.md).

- `Sources/SessionMoverKit`: all logic, no UI (InstanceCatalog, SessionIndex, LiveState, MoveEngine, FormatGuard, WritePolicy, AppController, CopyLauncher). Designed to be embeddable, e.g. in Claude Profiles.
- `Sources/SessionMover`: thin SwiftUI app. `Sources/smctl`: CLI over the same Kit.
- `SM_HOME=<dir>` points every home path (and `<dir>/Applications`) at another tree, e.g. a fixture.
- `spike/`: the Phase 0 Python script that proved the move recipe; `scripts/live-*.sh` repeat the live tests on throwaway copies.

## Docs

- [docs/phase0-findings.md](docs/phase0-findings.md): how Claude stores sessions, and why both copies must quit during a move
- [docs/PLAN.md](docs/PLAN.md): plan and architecture
- [docs/ux-spec.md](docs/ux-spec.md): UX spec

## License

Apache License 2.0. See [LICENSE](LICENSE).
