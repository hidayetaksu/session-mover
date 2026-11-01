# Phase 0 findings

Spike run 30–31 Oct 2026 on Claude desktop **4.29.0** (all copies on this Mac except Client, 3.6556.2). Experiments used two throwaway Claude Profiles copies, `test1` and `test2` (bundle ids `com.anthropic.claudefordesktop-test1/-test2`), a scratch repo `~/code/sm-spike-repo`, and throwaway Claude Code sessions created for the spike. The user's real copies (Claude, Work, Client, Lab) were only read. No real session was moved, and no transcript was written.

Evidence types: **[exp]** an experiment on test1/test2, with log lines from `~/Library/Logs/Claude/main.log` (every copy logs to this one file); **[code]** minified excerpts from `Claude.app/Contents/Resources/app.asar` 4.29.0, as `file@offset` under `.vite/build/` (B = `index.chunk-BbMIW0DP.js` LocalSessionManager, P = `index.chunk-DIQlva-3.js` WorktreePool, W = `index.chunk-Bt-5MUXl.js` GitWorktreeManager, A = `index.chunk-BaALgXPu.js`).

## Short answers

| # | Question | Answer |
|---|---|---|
| 1 | Does a running copy notice entries added/removed, or rewrite them from memory? | It does **not** notice added or removed files; the folder is read once per launch or account switch. It **does** rewrite a removed entry from memory on the next save of that session. **The source copy must be quit.** The destination must be relaunched to show the session. |
| 2 | Is an entry from another account/org accepted unchanged? What is rewritten on first open? | **Accepted unchanged**: nothing checks the file against the account. On first open Claude fills `remoteMcpServersConfig` (from the current org), `cliBinaryPin`, `gitAnchors`, `promptAppendSnapshot`, `pendingSystemReminder`, `lastFocusedAt`, `lastSpawnRootDetected`. |
| 3 | Where are sidebar groups and pins kept? | **Pins**: an account-level setting synced from the server, cached in each copy's `claude_desktop_config.json` (`epitaxyPrefs.starred-local-code-sessions`) and mirrored in the entry's `isStarred`. Same account: the pin follows the id automatically. Other account: lost, and it can't be written locally. **Groups**: group names/sections sync per account (`dframe-code-sections`); **membership is local per copy**, keyed `<account>/<org>` in `epitaxyPrefs.dframe-group-scopes`, and can be moved by editing that file while the copy is quit. |
| 4 | What do `deleted_<id>` tombstones do? Can they purge a history file? | A tombstone (`deleted_<cliSessionId>`, content = ms timestamp) only hides that transcript from the *Import CLI sessions* list. Transcripts are removed only at the moment of a user **Delete**, and only if no entry on disk in that copy's roots claims them and no process is using them. **A move never writes a tombstone**, so it can't purge anything. Risk to note: a Delete in one copy doesn't see entries in other Claude Profiles copies (see details). |
| 5 | How does `git-worktrees.json` GC treat a lease whose session is gone? | It is ignored at first. If the same copy keeps seeing it for **24 h of continuous runtime** (`ccWorktreeReapAfterHours`), the pool sweep **reclaims** it: a clean worktree is parked (HEAD detached, `leasedBy: null`, handed to the next new session) or deleted; a missing dir's record is pruned. **So the lease must be removed from the source.** The destination recovers on its own when the session opens ("had lost its lease; leased it back in place"); transferring the record just makes it explicit. |
| 6 | What is `archived-sessions.idx`? | `{"v":1,"archived":[local_…]}` per org folder: a **load-order hint** only. Listed ids load in a deferred second pass; the entry's `isArchived` is the truth. Claude rewrites the file from the entries after loading. |
| 7 | Must session families move together? | **No.** A child whose parent is elsewhere loads and opens normally (shown standalone; it nests again when the parent is back). Exceptions: a child that **shares the parent's checkout** (`spawnedFrom.sharedCheckout`, `btwSharedTree`) can't start sub-sessions, or fails with "hostGone", without its host. A parent's `side-session-notes/<parentId>` folder is per copy and should travel with it. Preflight warns; it doesn't block. |
| 8 | Is an account's id the same in every copy? | **Yes.** Account and org ids are server ids. test1, test2 and Work all store the same account under `af49c28e…/551669f7…`, and org `551669f7…` appears under three different accounts across Work and Client. Name each account once. |

**Must copies be quit during a move?** The **source must be quit**. It is proven to write a moved-away entry back (Q1). The **destination should be quit** (or relaunched afterwards). Moving into it while it runs is harmless, but the session only appears after a relaunch or account switch, and quitting both keeps their prefs and worktree files consistent. A move inside one copy (between accounts) quits that copy. Busy sessions block; an idle open session only warns, since quitting ends its process.

## Full-move recipe (as implemented in `spike/move.sh`)

1. **Preflight.** Find `local_<id>.json` in the source copy. Destination folder = `<dest data>/claude-code-sessions/<account>/<org>/`, where account defaults to the destination's `lastKnownAccountUuid` and org to the source's org when present. Block if the id already exists at the destination, if the session is **busy** in `~/.claude/sessions/<pid>.json` (live pid, `status: busy`), or if the destination already leases the same worktree name to another session. Warn on: idle open session, working folder gone, app versions differ, linked sessions left behind (`spawnedFrom`, `forkedFromSessionId`, children), pinned and moving to another account.
2. **Quiesce.** Quit source and destination by bundle id (`tell application id "<bundle>" to quit`), wait for `<Name>.real` to exit. Then re-check that no Claude Code process still holds the session (else reopen and stop: nothing changed).
3. **Journal and backup.** Copy every file the move can touch (source entry, destination path, both `git-worktrees.json`, both `archived-sessions.idx`, both `claude_desktop_config.json`) to `~/Library/Application Support/SessionMoverSpike/backups/<move id>/` with `journal.json`.
4. **Write the destination entry.** Copy byte for byte except: drop `cliBinaryPin`; across orgs set `remoteMcpServersConfig: null` (Claude refills it on open); drop a usage-limit `error`. Write to a temp name that **does not start with `local_`** (Claude promotes leftover `local_X.json.tmp` files into entries), `fsync`, `chmod 600`, `rename`.
5. **Worktree lease.** Move every `worktrees.<name>` record with `leasedBy == local_<id>` from the source `git-worktrees.json` to the destination's (all fields kept, mode 600). Within one copy nothing changes.
6. **Group membership.** Move `code:local_<id>` from `dframe-group-scopes[<src acct>/<src org>]` to the destination scope, adding the group definition if missing. Pins are left to Claude's account sync.
7. **Archive hint.** Remove the id from the source `archived-sessions.idx`; add it to the destination's if the entry is archived and the file exists (Claude rebuilds it anyway).
8. **Per-session side files.** Move `waiting-input/<id>*` (Claude deletes records whose id is not in that folder). Copy `side-session-notes/<id>/` across copies.
9. **Verify, then remove the source.** Destination entry reads back equal → delete the source entry → journal `done` → reopen the copies that were running.
10. **Undo** (`move.sh undo <move id>`): quit both, restore every backed-up file, delete files that didn't exist before, reopen.

## Runs

Full output: [phase0-runs.log](phase0-runs.log). Each move is followed by `spike/verify.sh`. It opens the destination, sends `claude://resume?session=<cliSessionId>` to that copy only, and requires the log line `already imported as local_<id>`. That line proves the copy loaded the moved file; a fresh import would log `Imported CLI session`. It also checks that the source has no entry. Screenshots of the sidebar were also checked after each series.

| Series | Moves | Result |
|---|---|---|
| Intermediate script | worktree session test1→test2; pinned session test1→test2; `undo` of that; then pinned test1→test2, worktree test2→test1, grouped test1→test2 | all PASS |
| After the pin/group change | grouped test2→test1 (group carried), worktree test1→test2 (lease moved), pinned test2→test1 (pin followed via account) | 3/3 PASS |
| Cross-account + cross-org in one copy | test1 `af49c28e/551669f7` → `d07e51d4/52e67e65` (`remoteMcpServersConfig` and `cliBinaryPin` cleared) and back | PASS |
| **Final, committed script** (`sha1 4001df1b…`) | grouped test1→test2; worktree test2→test1; grouped test2→test1 | **3/3 PASS** |

## Details and evidence

### Q1. Live folder behaviour

- **[exp] Added while running: not noticed.** At 23:49:09 three entries were moved into test1's signed-in folder while test1 ran. One minute later the sidebar still said "No sessions match the current filters". After a normal quit and reopen all three were listed.
- **[exp] Removed while running, no save: not rewritten.** Two loaded entries (one opened) were removed at 23:51:29, then test1 quit normally. Neither file came back (`onQuitCleanup handlers done: 308ms`, folder still without them).
- **[exp] Removed while running, then saved: rewritten.** At 23:52:18 the focused session's file was removed. Focusing another session and then it again (`claude://resume`) recreated it at 23:52:27 (`local_5b30….json` 31,920 bytes).
- **[code]** B@1912265 `loadSessionRecords`: one `readdir(getStorageDir())`, where `getStorageDir()` = `<userData>/claude-code-sessions/<currentAccountId>/<currentOrgId>`; it skips ids already in memory (`if(this.sessions.has(T.sessionId)…)return`). No `fs.watch`/chokidar on that folder. Saves go to `getSessionFilePath(id)` in the current account folder, so any later `saveSession` of an in-memory session recreates a moved-away file.
- **[code]** Account switch keeps the old account's sessions *parked* in memory and flushes them (B `retireParked … await this.persistence.flush(e)`). So moving out of a *hidden* account folder while the copy runs isn't safe either, if that account was active earlier in the same run.

### Q2. Cross-account/org entries

- **[exp]** Entries imported under the Free account `d07e51d4…/52e67e65…` were moved into `af49c28e…/551669f7…` (other account and org) and loaded unchanged: mtimes untouched by loading. Opening one logged `already imported`, `Warming session …`, `replaceRemoteMcpServers: … serverCount=2`, `warmed successfully`. JSON diff before/after first open (other keys identical):
  ```
  cliBinaryPin: null -> {"version": "2.1.309", "wrapper": "0.3.309", ...}
  gitAnchors: null -> [{"gitRoot": ".../sm-spike-repo", ...}]
  lastFocusedAt / lastSpawnRootDetected / promptAppendSnapshot / pendingSystemReminder: set
  remoteMcpServersConfig: null -> [{"uuid": "1a59c906-…", "name": "Claude Docs", ...}]   (current org's connectors)
  ```
- **[code]** B@1912265: `A.homeTenancy={accountId:this.currentAccountId,orgId:this.currentOrgId}` is set in memory on load and not serialized; nothing compares file content to the account. The loader normalizes in memory and saves only in narrow cases (see agent notes, A `iN`).
- Consequence: the plan's rewrite rules are safe and mostly cosmetic. Clearing `remoteMcpServersConfig` across orgs avoids a stale connector list until first open, and clearing `cliBinaryPin` lets the destination pick its own CLI.

### Q3. Pins and groups

- **[exp] Pin.** After pinning in test1: entry `isStarred: true`, and `claude_desktop_config.json` → `preferences.epitaxyPrefs.starred-local-code-sessions: ["local_c2a0…"]`. Moving the entry alone to test2 showed it **unpinned**, since test2's list was empty. Editing the lists by hand did not stick: removing the id from test1's list and adding another id to test2's, then relaunching, gave **both copies `["local_c2a0…"]`**. The hand-added pin was dropped and the removed one restored, with test1 logging `Cannot update session: local_c2a0… not found`. The list comes from the account (server), and the file is a cache. Both copies were on the same account, which is why the pin followed in the later runs.
- **[exp] Group.** Creating "SpikeGroup" wrote to the same file: `dframe-group-scopes["af49c28e…/551669f7…"] = {groups:[{id:"cg-5f2e…",name:"SpikeGroup",mode:"code"}], assignments:{"code:local_b968…":"cg-5f2e…"}, order:{…}}` plus a section in `dframe-code-sections[…]`. test2 later had the *section* (synced) but an empty `dframe-group-scopes` (local). Writing the assignment into test2's file while it was quit made SPIKE-3 appear under SpikeGroup after launch, and it persisted. The script now does this.
- **[code]** Main process keeps groups only as an in-memory cache filled by the renderer (`LocalSessions.setCustomGroups({accountUuid,orgUuid,groups,assignments})`, B@50445 class `ki`). `isStarred`/`color` are serialized in the entry (A `$M`), pushed by the renderer via `updateSession` (B@2249292).

### Q4. Tombstones and history

- **[exp]** Deleting "SPIKE-2" (cli id `d21a…`) in test1 (the same transcript was also imported in test2) produced:
  - `deleted_d21a0344-…` in test1's org folder, content `1793430975039` (ms timestamp);
  - `~/.claude/projects/…/d21a0344-….desktop-released.json` = `{"v":1,"releasedAt":"2026-10-31T07:16:15.659Z","reason":"delete"}`;
  - log `[CCD] transcript d21a0344-… is in use by a Claude Code process; left on disk for Claude Code's periodic cleanup`. The transcript survived only because a process had it open. Later, test2 opening its copy removed the marker; the transcript is still there.
- **[code]** B@1083 kB: `TW` writes `deleted_<cliId>`; `MW` collects tombstones of the current account and *every* `local_*.json` claim; CliSessionDiscovery (`index.chunk-BrfjLqCK.js`) excludes `tombstoned` ids only from the **sidebar CLI-import list** (`t==="sidebar"?a.tombstoned:[]`). Transcript removal (`bW` … `rm`) runs only from the user-delete path (B@2027864), gated by `mayRelease: !cliSessionIdsClaimedOnDisk().has(id)` and `reapIf` (process not running, idle checks). Importing the same id removes tombstones (`OW(d,[e])`).
- `cliSessionIdsClaimedOnDisk` scans this copy's `claude-code-sessions` (all accounts) plus "sibling roots" (`ZW`: fixed names `Claude`, `Claude-3p`, … under the app-data dir). A Claude Profiles copy runs with `--user-data-dir ~/.claude-profiles/<slug>/…`, so **other profile copies are not checked**. Phase 1+ consequence: after *Open a copy*, deleting the session in one copy can delete the transcript the other copy still uses. Archive instead of delete, or warn. A full move is unaffected, since it never leaves two entries.

### Q5. Worktree leases

- **[exp]** Importing a CLI session that runs inside `sm-spike-repo/.claude/worktrees/spike-wt` made test1 adopt it: `worktrees.spike-wt = {leasedBy:"local_803f…", adopted:true, branch:"claude/spike-wt", anchors:[…]}`.
- **[exp] Lease left behind.** The record was put in test2 (where the session is not) and removed from test1 (where it is). On open, test1 logged `[CCD] Worktree at …/spike-wt had lost its lease; leased it back in place on branch claude/spike-wt` and wrote a new record. test2 kept the stale record untouched for the following ~10 minutes, through its first sweep. Both copies then claimed the same worktree.
- **[code]** P `reclaimableOrphans`: a record whose lessee isn't held by this copy is tracked in the in-memory `unknownLesseeSince` and becomes reclaimable after `reapAfterMs` (pref `ccWorktreeReapAfterHours`, default 24 h, reset on each launch). `sweep()` (60 s after start, then every 30 min; needs the pool flag and `hasCompleteSessionRoster()`) then prunes missing dirs, leaves dirty trees alone, and for clean trees reaps beyond `ccMaxWarmWorktrees` (3 per repo) or **parks** them (`detachWorktreeHead`, `setWorktreeLeasedBy(name,null)`), so `tryAcquire` can hand the path to a new session. A copy that runs for a day with a stale lease can therefore detach or delete the worktree the moved session uses. Hence step 5 of the recipe.
- **[code]** B@1675400 `tryWorktreeFallback` on open: `adoptUnknownLease` → `reattachOwnWorktree` (needs managed path, HEAD on the session's branch) → pool → new worktree → else fall back to `originCwd` and clear the worktree fields. A destination without a record recovers by itself in the normal case.

### Q6. `archived-sessions.idx`

- **[exp]** test1: entry SPIKE-1 set `isArchived: true`; idx written listing only the *active* "Say hi". On launch: `Loaded 2 persisted sessions … (1 archived deferred, 1 of them unopened; hint used)`, then `Loaded 1 deferred archived sessions … (after_active, 289 ms)`. "Say hi" still showed as active, and the idx was rewritten to `{"v":1,"archived":["local_5b30…"]}`, i.e. derived from the entries.
- **[code]** B@1735033 `Q3/$3`: format `{v:1, archived:[sorted ids]}`; unreadable → `archived-sessions hint unreadable (...); loading without it`; class `n6` rewrites it after changes (debounced 250 ms).

### Q7. Session families

- **[exp]** "Say hi" got `spawnedFrom` = SPIKE-4 and spike-wt got `forkedFromSessionId` = SPIKE-3, while both parents were in test2. Both loaded, opened and warmed in test1 with no errors. Later, with SPIKE-4 moved back into test1, "Say hi" was shown nested under it. The family link is just a pointer that resolves when present.
- **[code]** Host resolution walks `spawnedFrom` only while `sharedCheckout===true && held(parent)`; missing parent → the child is its own host. Shared-checkout children without the host: "This session can't start a session on this computer: the session whose folder it shares can't be found…"; `btwSharedTree` children throw `SharedWorktreeGoneError` ("hostGone") on warm. `side-session-notes/<parentId>` lives in each copy's data folder (B@1207966).
- Recommendation: warn and offer "move the family", and block only children with `spawnedFrom.sharedCheckout`/`btwSharedTree` whose host stays behind.

### Q8. Account ids

- **[exp]** test1 and test2 signed in to the same account show `lastKnownAccountUuid = af49c28e-8815-…` and org `551669f7-f059-…`, identical to Work's folder for that account. Client's account `7bea2ef2…` and Work's `f0346467…`/`af49c28e…` all use org `551669f7…`. These are server-issued ids, so AccountLabels can key by account id across copies.

## Other things found

- Claude Profiles copies all write to the same `~/Library/Logs/Claude/main.log` (no per-copy tag), and the window owner name changes after a relaunch (`test1` → `Claude-test1`). Phase 1 should match processes by bundle id, not name.
- `quit` by bundle id finished within 1–2 s on every quit in the spike; no dialog blocked a quit. A real copy with busy sessions may take longer or ask.
- After switching accounts, test1 also wrote `scheduled-tasks.json` under `<old account>/<new org>`, a stray folder. SessionIndex should tolerate org folders with no entries.
- Copies cloned from different builds (Client 3.6556.2) were not tested. FormatGuard should allow full moves only on 4.29.0 until re-verified.

## Recommendations for Phase 1–2

1. Keep "quit both copies" as the default and only mode for a full move. A live move is not possible without Claude's cooperation (Q1).
2. MoveEngine = the recipe above. Port `sm_move.py` to `SessionMoverKit`. Its unit tests can use copies of the spike's fixture files.
3. Show pins as account state: no file writes, and warn when moving to another account.
4. Treat *Open a copy* + Delete as a transcript-loss risk (Q4) and say so in the copy sheet.
5. Treat the 4.29.0 formats observed here (`git-worktrees.json` schemaVersion 2, idx `v:1`, `epitaxyPrefs` keys) as FormatGuard's first verified set.

## Addendum: Claude 4.4212.0 (1 Nov 2026)

Verified for full moves. FormatGuard lists it in `verified-versions.json`.

- **Static comparison** (4.29.0 vs 4.4212.0 `app.asar`): the session persistence code is the same apart from renamed identifiers. Same folder layout and `local_` filter, same atomic writer and `.tmp` promotion, still loaded once per launch or account switch with no watcher, still saved by id (so the source must still quit). `git-worktrees.json` is still schema 2 with the same 24h pool sweep. The deep-link resume handler and its log lines are unchanged. Tombstones and transcript reaping are unchanged; delete can now set a transcript aside (`.jsonl.desktop-deleted-<nonce>`) and put it back at load.
- **The "six new keys"** (`armedWorkAtQuit`, `chromeAllowedDomains`, `chromeTabGroupId`, `forkedAtMessageUuid`, `interruptedByQuitAt`, `promptSuggestion`) already existed in 4.29.0's serializer; none is bound to a copy, account or organization. The rewrite rules are unchanged (drop `cliBinaryPin`, null `remoteMcpServersConfig` across orgs, clear a usage-limit error).
- **Sidebar groups:** after test1/test2 ran on 4.4212.0, `epitaxyPrefs.dframe-group-scopes["<acct>/<org>"]` still has `{groups, assignments, order}` with the same assignment.
- **Live, on test1/test2 updated to 4.4212.0:** 3 round trips (6/6 PASS through `spike/verify.sh`), Quit & Move with both copies running, kill after the lease step then Finish, kill after writing the destination then Roll Back (every file identical by sha1), Open a Copy then Archive Copy. All passed.
