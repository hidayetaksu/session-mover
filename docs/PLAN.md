# Session Mover: plan (technical sections)

Source: the plan page published 29 Oct 2026 (https://claude.ai/artifact/LL2vWTYuDiccm1pYaRHKsq). The UX spec is in [ux-spec.md](ux-spec.md). This file keeps the technical parts; the interactive prototype stays on the page.

A companion app to Claude Profiles that shows every Claude Code session from every copy of Claude and every account on this Mac in one window, and moves a session from one copy or account to another by drag and drop.

## Why

Claude shows a Claude Code session only in the copy of the app, and for the account, it was created in. When one account hits its weekly limit and that copy is switched to another account, every session disappears from the sidebar. On 27 Oct 2026 bringing one back took a terminal command, a hand-built `claude://` link aimed at the right copy, and *Choose folder* because Claude picked a worktree deleted weeks earlier.

## What is on disk

Read from this Mac on 29 Oct 2026. None of it is a documented format, which is why Phase 0 exists.

| Thing | Where it lives | What the app does with it |
|---|---|---|
| Claude app copies | `/Applications/Claude.app` plus Claude Profiles clones `/Applications/Claude-<slug>.app`, bundle id `com.anthropic.claudefordesktop-<slug>` | One sidebar entry per copy. Name, accent colour and SF Symbol from `~/Library/Application Support/ClaudeProfileManager/profiles.json`. |
| Each copy's data | `~/Library/Application Support/Claude` (original), `~/.claude-profiles/<slug>/Library/Application Support/Claude` (clones) | Read `config.json` for `lastKnownAccountUuid` only. It also holds OAuth token caches, which the app never reads. |
| Sidebar entries | `claude-code-sessions/<account>/<org>/local_<id>.json` | The unit of a move. ~424 entries, ~90 distinct fields. |
| Per-account side files | Same folder: `archived-sessions.idx`, `deleted_<id>` tombstones, `scheduled-tasks.json`, `waiting-input`, `backlog` | Kept consistent with a move. |
| Conversation history | `~/.claude/projects/<encoded folder>/<cliSessionId>.jsonl`, shared by every copy and account | Never touched. |
| Running sessions | `~/.claude/sessions/<pid>.json` with `hostSessionId`, `status` (idle/busy) | Running and busy chips. A running session cannot be moved. |
| Worktree leases | `git-worktrees.json` in each copy's data folder, `worktrees.<name>.leasedBy: local_<id>` | Moved with the session. |
| Who is running | `NSRunningApplication` by bundle id | Quit and reopen during a full move. |

```
~/.claude-profiles/work/Library/Application Support/Claude/
├─ config.json                     lastKnownAccountUuid = eb90b3bb…
├─ git-worktrees.json              worktree leases, per session
└─ claude-code-sessions/
   ├─ eb90b3bb…/                   account A
   │  └─ 2a5d8f8f…/                organization
   │     ├─ local_9d4daf90….json   one sidebar session
   │     ├─ archived-sessions.idx
   │     └─ scheduled-tasks.json
   └─ 42b27042…/                   account B
      └─ 2a5d8f8f…/ …
~/.claude/projects/…/9d4daf90….jsonl   shared history, never moved
```

## Two ways to move a session

|  | Full move (default) | Open a copy (Option) |
|---|---|---|
| How | Moves `local_<id>.json` and its worktree lease between folders | `open -b <bundle id> 'claude://resume?session=<cliSessionId>'`, the same import as *Import Claude Code CLI Sessions…* |
| Supported by Claude | No. Internal files, guarded by Phase 0 and a version check | Yes |
| Apps must quit | Source and destination copies, while files move (see Phase 0 findings) | No |
| Title and full history | Kept | Kept |
| Folder, branch, worktree | Kept | Starts in the first folder the session used, often deleted |
| PR links, model, effort, permissions | Kept | Model and permission mode kept; PRs dropped |
| Source keeps a copy | No | Yes; never run both at once |
| Undo | Yes, from the journal | Archive the copy |

## A full move, step by step

1. **Preflight.** Per session: not running, not busy; destination differs from source; no entry with the same id at the destination; folder exists; worktree lease found or absent; same or different organization; linked sessions (forks, side sessions) that stay behind. Any block stops the move; warnings need a click.
2. **Quiesce.** Ask source and destination copies to quit (`terminate()`), wait for exit. Refuse if a session is busy.
3. **Journal and back up.** Write a journal record, then copy every file the move touches (entry, both `git-worktrees.json`, both archive indexes) into `~/Library/Application Support/<app>/backups/<move id>/`.
4. **Write the destination.** Rewrite the entry (rules below), write to a temp name in the destination folder, rename into place.
5. **Transfer the worktree lease** between `git-worktrees.json` files, keeping every other field and mode 0600.
6. **Update archive indexes** when the session is archived.
7. **Remove the source entry**, only after the destination entry reads back and parses.
8. **Verify**, mark the journal done, reopen the copies that were running.

A crash at any step leaves an unfinished journal record; the next launch finishes or rolls it back and says which.

## What changes inside the entry

| Field | Same organization | Different organization |
|---|---|---|
| Everything not listed | Copied byte for byte, including unknown fields | same |
| `remoteMcpServersConfig` | Kept | Cleared: connector ids belong to an organization |
| `publishedArtifacts` | Kept | Kept as links, flagged in preflight |
| `error`, `errorAt`, `errorRows` | Cleared when the error is a usage limit | same |
| `cliBinaryPin` | Cleared, so the destination picks its own Claude Code version | same |
| `cwd` | Kept. If gone and history shows a later existing folder, preflight offers it | same |

## Rules the move engine never breaks

- Never reads or writes conversation history, OAuth tokens or `config.json`.
- Never moves a running session, and never moves while a copy it touches is running.
- Never deletes a source file before the destination file reads back.
- Never writes into an app version it has not seen; unknown versions get only *Open a copy*.
- Keeps every backup until the user empties History.

## Architecture

Native SwiftUI app, macOS 14+, AppKit where needed (outline drag and drop, spring-loaded rows). Not sandboxed; Developer ID, notarized.

| Module | Job |
|---|---|
| InstanceCatalog | Finds Claude copies from `profiles.json`, `/Applications` and Launch Services; maps each to data folder and bundle id. |
| SessionIndex | Reads every `local_*.json`, watches folders with FSEvents. Read-only. |
| LiveState | Running copies (`NSRunningApplication`) and running/busy sessions (`~/.claude/sessions`). |
| AccountLabels | User-given names for account ids, in the app's own settings. |
| MoveEngine | Preflight, quiesce, journal, backup, write, verify, undo. The only code that writes outside the app's folder. |
| CopyLauncher | *Open a copy*: `NSWorkspace.open(_:withApplicationAt:)` with the deep link, aimed at one copy by bundle id. |
| FormatGuard | Known app versions and their entry fields; decides whether a full move is allowed. |

All logic lives in a `SessionMoverKit` Swift package with no UI; the SwiftUI app stays thin, so MadAppGang could adopt the package into Claude Profiles.

### Fitting Claude Profiles

- Reads `profiles.json` for name, slug, accent colour, SF Symbol; never writes it.
- Each clone's `Contents/MacOS` holds a launcher (`<Name>`) and the renamed Claude binary (`<Name>.real`); the launcher adds `--user-data-dir`. Reopen with `NSWorkspace.openApplication(at:)` on `Claude-<slug>.app`, never on `.real`.
- Quit by bundle id with a normal quit, never a force quit.

## Phases

| Phase | Builds | Done when |
|---|---|---|
| 0 · Spike (2–3 days) | Scripts: answer the questions below on a throwaway Claude Profiles copy | Every question answered in writing; the full-move recipe works three times in a row on the throwaway copy |
| 1 · Browser | Window with every copy, account, session; search, filters, chips; Reveal in Finder; Open in its app | Counts match the folders; chips match `~/.claude/sessions` |
| 2 · Move | MoveEngine with apps quit, drag and drop, Move to…, journal, Undo, History | Moves between accounts and copies survive quit/relaunch; Undo restores the source byte for byte |
| 3 · Copy and orchestration | Open a copy; one-click quit, move, reopen; recovery of unfinished moves | A move with both copies running completes without manual quitting; a kill mid-move is recovered |
| 4 · Polish | Multi-select, menu bar extra, FormatGuard updates, notarized release | Signed, notarized build installed |
| 5 · Offer upstream (optional) | Share `SessionMoverKit`, UX spec and plan with MadAppGang | They answer yes or no |

## Phase 0 questions

Answered in [phase0-findings.md](phase0-findings.md).

1. Does a running Claude copy notice a `local_*.json` added or removed under it, and does it ever rewrite the folder from memory? (Decides whether copies must quit.)
2. Does Claude accept an entry from another account or organization without changes, and which fields does it rewrite on first open?
3. Where are sidebar groups and pins kept: in the entry, `Local Storage`, or on the server?
4. What do `deleted_<id>` tombstones do? Does a tombstone at the source make Claude purge a shared history file the moved session still needs?
5. How does `git-worktrees.json` garbage collection treat a worktree whose lease points at a session the copy no longer has?
6. What does `archived-sessions.idx` hold; is it the source of truth or a hint?
7. Do session families (`spawnedFrom`, `forkedFromSessionId`, side sessions) need to move together?
8. Is an account's id the same in every copy of the app?

## Risks

- Claude updates change the format (copies here were cloned from 3.6556.2 and 4.29.0). FormatGuard falls back to *Open a copy* on unverified versions.
- A move while a copy runs corrupts its list. Until Phase 0 proves otherwise, a full move quits both copies.
- Two copies of one session run at once after *Open a copy*. The source row gets a "Copied to …" note.
- Undo after the session was used would drop what the destination wrote since. Restore compares and warns first.
- Claude Profiles changes its layout. The app also scans `/Applications` for `com.anthropic.claudefordesktop*`.

## Decisions

- 29 Oct 2026: a standalone companion to Claude Profiles, logic in `SessionMoverKit`.
- Code lives in `~/code/claude-session-mover`.
- Open: whether copies quitting for a move is acceptable as the default (see Phase 0 findings).
