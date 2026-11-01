# Session Mover: UX spec

A native macOS utility that shows every Claude desktop instance on this Mac in one window and moves Claude Code sessions between instances and accounts, safely and reversibly.

Status: design only. Companion mockup: `mockup.html` (interactive fragment of the main window).

---

## 1. Name

| Candidate | Read |
|---|---|
| **Session Mover** | Says exactly what it does. Matches the working repo name `claude-session-mover`. |
| Session Desk | Suggests a browser more than a mover. |
| Instances | Plain, but says nothing about sessions. |

**Pick: Session Mover.** It names the one job people open it for, and it reads correctly in a menu bar, a Dock tooltip and a Finder window.

---

## 2. Information architecture and main window

### Model the user sees

```
Instance (a copy of Claude.app: name, accent colour, SF Symbol, running or quit)
└─ Account (labelled by the user; one is "signed in now")
   └─ Organization (shown only when an account has more than one)
      └─ Session (one sidebar entry in Claude)
```

Conversation history sits outside this tree on purpose: every instance reads the same `~/.claude/projects`, so the UI treats history as shared ground and says so wherever a move is confirmed.

### Window

Three-pane `NavigationSplitView`, minimum 900 × 560, default 1100 × 680.

| Pane | Width | Content |
|---|---|---|
| Sidebar (source list, vibrancy) | 220–280 | Library, Instances, History |
| Session list | flexible, min 380 | Scope bar, grouped rows |
| Inspector | 280–340, collapsible | Selected session, or a selection summary |

### Sidebar

| Section | Rows | Notes |
|---|---|---|
| **Library** | All Sessions (424) · Hidden in Their App (82) · Running (3) · Needs Attention (2) | Smart lists across every instance. *Hidden in Their App* is the direct answer to "my sessions vanished": sessions in an account that their instance is not signed in to right now. |
| **Instances** | One disclosure row per instance, account rows beneath | Order: original Claude first, then Claude Profiles order. |
| (bottom) | History | Clock symbol. Badge when a move needs attention. |

**Instance row:** 20 pt rounded-square tile filled with the instance accent, its SF Symbol in white; name; trailing state.

| Instance state | Trailing glyph | VoiceOver |
|---|---|---|
| Running | small filled dot, secondary colour | "running" |
| Quit | nothing | "not running" |
| Has a busy session | `circle.dotted` animated (static with Reduce Motion) | "running, a session is busy" |
| Scan error | `exclamationmark.triangle.fill` in yellow | "could not be read" |
| Version not verified | `lock.fill` small | "moves use Open a copy only" |

Identity rule: accent and symbol always appear together with the name. On this Mac Work and Client share `wrench.fill`, and Client and Lab share `#D97706`, so neither colour nor symbol identifies an instance on its own.

**Account row:** indented under its instance; symbol, label, count. Signed in now: `person.crop.circle.fill` in the system accent, tooltip "Signed in to Work now". Not signed in: outline `person.crop.circle` in secondary colour plus a trailing `eye.slash`, tooltip "Hidden in Work. Work is signed in to Team account." (A "Signed In" text capsule was tried in the mockup and truncated every email at sidebar width; the symbol carries the state, and menus spell it out as "Signed In".) Unlabelled accounts show the ID tail in mono secondary text (`3c91e0a7`) with an inline **Name…** button; VoiceOver reads "Account 3c91e0a7".

Selecting an instance shows all its accounts' sessions, grouped by account then project. Selecting an account scopes to that account.

### Toolbar (unified, compact)

Left to right: sidebar toggle · window title and subtitle (scope name; "82 sessions · 24 archived") · flexible space · **Move To…** (`arrow.right.square`) · **Open a Copy In…** (in the Move To menu only, not a separate button) · History (`clock.arrow.circlepath`) · inspector toggle · search field.

### Scope bar (under the toolbar, Finder-style)

| Control | Values | Default |
|---|---|---|
| Filter (single choice) | Active · Archived · Running · Errors · All | Active |
| Sort (menu) | Last Activity · Title · Project · Created | Last Activity, newest first |
| Group by Project (toggle button, `folder` symbol, ⌃⌘G) | on / off | on |

Each filter button shows a count in tabular figures. *Errors* includes usage-limit errors, missing folders and unreadable files. *Running* includes idle and busy.

### Search

Toolbar search field (⌘F). Matches title, folder name, branch, PR number (`#843`) and model. While typing, a scope token row appears under the field: **This Account** · **All Instances**. Results keep the project grouping and show the instance tile on each row when the scope is All Instances.

### List grouping

Section header per project folder: folder name in semibold, path tail in secondary text, count trailing. Sections collapse with the disclosure triangle; collapse state is remembered per scope.

### Hidden banner

When the scope is an account its instance is not signed in to (or *Hidden in Their App*), a tinted banner sits above the list: **82 sessions are hidden in Work.** Work is signed in to Team account, so it shows only that account's sessions. Drag these to a signed-in account to see them in Claude again. It names the cause in the user's own terms and points at the fix; it is the screen this app exists for.

### Toolbar title

Title is the scope (instance name, or smart list name); subtitle carries the account and counts in tabular figures: "you@example.com · 82 sessions · 24 archived · hidden in Work".

---

## 3. Session row anatomy

Two-line row, 52 pt tall, 12 pt horizontal inset. All metrics fixed so chips never change row height.

```
┌────────────────────────────────────────────────────────────────────┐
│ [▣]  Trip data validation and VIN auto-population        2 min ago │
│      web-app · claude/vin-autofill    [● Busy] [PR 3]            │
└────────────────────────────────────────────────────────────────────┘
```

| Slot | Content | Style |
|---|---|---|
| Leading (only in All Sessions, search across instances, smart lists) | 16 pt instance tile | accent + symbol |
| Line 1 | Title, one line, tail truncation | 13 pt regular, primary; semibold when selected |
| Line 1 trailing | Last activity: "2 min ago", "Yesterday", "Oct 23" | 11 pt, secondary, tabular figures |
| Line 2 | Project folder name · branch (or worktree name) | 11 pt, secondary; branch in `SF Mono` 11 pt |
| Line 2 trailing | Chips, max three, then "+1" | see below |

### State chips

Priority order when space is short: Busy > Running > Limit > Folder missing > Archived > PRs.

| Chip | Glyph | Text | Colour role | VoiceOver |
|---|---|---|---|---|
| Busy | `circle.dotted` (animated) | Busy | system accent fill | "Busy, mid-turn. Can't be moved." |
| Running | filled dot | Open | green | "Open and idle in Work" |
| Weekly limit | `hourglass` | Limit · Oct 29 | orange | "Weekly limit reached on this account, resets October 29 at 1 AM" |
| Folder missing | `folder.badge.questionmark` | No folder | yellow | "Working folder no longer exists" |
| Archived | `archivebox` | Archived | secondary gray | "Archived" |
| PRs | `arrow.triangle.pull` | 3 | neutral outline | "3 pull requests" |
| Copied | `doc.on.doc` | Copied | neutral outline | "A copy was opened in Client" |

Archived rows render at 70 % title opacity. A row with a usage-limit error shows the reset date, never the full error, in the list; the inspector shows the full string.

---

## 4. Drag and drop

### What can be dragged

Any session row, single or multi-selected (⌘-click, ⇧-click, ⌘A). Busy and running rows can be dragged so the reason they can't move is shown where the user is looking, at the target.

### Drag preview

| Selection | Preview |
|---|---|
| One session | A 280 pt capsule: instance tile, title (one line), and line 2 in secondary text. Material background, 8 pt radius, shadow. |
| Several | The same capsule for the first session with two offset cards beneath (pile formation) and a count badge: **3 sessions**. |

### Drop targets

| Target | Valid when | Highlight |
|---|---|---|
| Account row | At least one dragged session can move there | Rounded fill in system accent at 20 %, 1 pt accent ring; row text stays primary |
| Instance row (expanded or collapsed) | Same, resolves to the **signed-in account** of that instance | Same highlight on the instance row, and its signed-in account row gets a 1 pt ring so the destination is visible |
| Session list of a different scope | Never | No highlight |
| History, Library rows | Never | No highlight |

**Spring-loading:** hovering a collapsed instance for the system spring-loading delay (default about 0.7 s) expands it; the row blinks twice before opening (no blink with Reduce Motion). Pressing Space while hovering expands immediately, as in Finder. Instances that spring open close again when the drag ends without a drop on them.

### Invalid targets

The drop is refused (operation `[]`, the preview slides back) and the target shows a dimmed state with a `nosign` glyph. The cursor badge explains why.

| Case | Badge text |
|---|---|
| Same account the session is in | Already in Work · you@example.com |
| An account that already holds this session id | Already in Client · Team account |
| Busy session (all targets) | Can't move: "Data import validation…" is busy |
| Running session in an app that won't quit (CLI process) | Can't move: open in Terminal |
| Instance version not verified | Only Open a copy works here. Hold Option. |
| Mixed selection | Target stays valid; badge counts what will move: **Move 2 of 3 to Client · Team account** |

### Cursor badge

A label under the pointer, 11 pt medium, on a material capsule, updated as the target changes.

| Modifier | Badge | Cursor |
|---|---|---|
| none | **Move to Client · Team account** | arrow (move) |
| none, apps running | Move to Client · Team account / *Work and Client will quit and reopen* (second line, secondary) | arrow |
| Option | **Open a copy in Client · Team account** | arrow with green plus (copy) |

Option can be pressed or released mid-drag; the badge and the target highlight (accent for move, dashed accent ring for copy) follow it live.

### After the drop

A drop never moves files immediately. It opens the Move sheet (section 5) attached to the window. When every check passes and no app needs to quit, the sheet's default button is focused, so the whole move is one Return press.

---

## 5. The Move sheet

A window-modal sheet, 520 pt wide. Opened by a drop, by **Move To ▸ destination**, or by ⇧⌘M then a destination.

### Layout

```
Move "Refactor payment retry logic"
From Work · you@example.com  →  To Client · Team account

  ✓  Session isn't running
  !  Work and Client are open        They quit, then reopen after the move.
  !  "Sprint planning notes" is open in Work  Quitting closes it. It reopens from history.
  ✓  Working folder exists                     ~/…/acme/web-app
  ✓  Worktree lease moves with it              .claude/worktrees/payment-retry
  !  Different organization                    Connectors, published artifacts and
                                               scheduled tasks stay behind.
  ✓  Not in Client yet

  ⓘ  History comes along. Conversations live in ~/.claude/projects, which every
     instance reads. This move doesn't touch them.

  [✓] Reopen apps when done                     ▸ Show files

                                      [ Cancel ]  [ Quit & Move ]
```

### Check rows

Each row: status glyph (16 pt), check name (13 pt), detail (11 pt secondary, right column, wraps). Rows with a warning or block expand by default; passing rows stay one line. With several sessions, a row that differs per session shows "2 of 3" and expands to list them.

| Check | Pass | Warn | Block |
|---|---|---|---|
| Session state | Session isn't running | Open in Work and idle. Quitting closes it. | "…" is busy. Wait for the turn to finish, or stop it in Claude. |
| Apps involved | No apps need to quit | Work and Client are open. They quit, then reopen. | Work has a busy session: "…". It can't quit now. |
| Other open sessions | (hidden when none) | "Sprint planning notes" is open in Work. Quitting closes it. | (busy ones block under Apps involved) |
| Working folder | Working folder exists | Folder is missing. The session opens with "Choose a different folder". | (never blocks a full move) |
| Worktree lease | Worktree lease moves with it · No worktree | Lease not found. The worktree stays where it is. | (never blocks) |
| Organization | Same organization | Different organization. Connectors, published artifacts and scheduled tasks stay behind. | (never blocks) |
| Destination | Not in Client yet | (none) | Already in Client · Team account. → offers **Replace** |
| App version | Versions verified | (none) | Work 4.31.0 isn't verified yet. Use Open a Copy. |
| Usage-limit error | (hidden when none) | The weekly-limit notice from you@example.com is cleared on move. | (never) |

Glyphs: `checkmark.circle.fill` green, `exclamationmark.triangle.fill` yellow, `xmark.octagon.fill` red. Colour is never the only signal: every row also has its text.

### Buttons

| Situation | Default button | Secondary |
|---|---|---|
| All pass, no app to quit | **Move** | Cancel |
| Apps must quit | **Quit & Move** | Cancel |
| Some sessions blocked, others fine | **Move 2, Skip 1** (or Quit & Move 2, Skip 1) | Cancel |
| Everything blocked by a busy app | (disabled) **Quit & Move** | **Open a Copy Instead**, Cancel |
| Busy session itself | (disabled) **Move** | Cancel. A copy is not offered: the turn is still writing history. |
| Duplicate at destination | **Replace** (destructive style, needs ⌘⌫ or click) | Cancel |

Warnings never need a separate acknowledgement checkbox; reading them and pressing the default button is the acknowledgement. Blocks disable only the sessions they affect.

**Show files** discloses the exact source and destination paths and the backup folder, monospaced and selectable.

### Quit & Move orchestration

The sheet turns into a progress list in place (same size; the checklist collapses to a one-line summary above it). Each step: glyph · label · detail · elapsed time (tabular).

| # | Step | Detail while running | Done | Failure |
|---|---|---|---|---|
| 1 | Quit Work and Client | Waiting for Work… | Quit in 1.4 s | Work didn't quit. **Show Work** · **Try Again**. Never force-quits. |
| 2 | Back up | 4 files | Backed up 4 files | Disk full. Nothing changed. |
| 3 | Move session file | local_9d4d….json | Moved 1 file | Rolled back. Nothing changed. |
| 4 | Transfer worktree lease | git-worktrees.json | Lease transferred | Rolled back. Nothing changed. |
| 5 | Verify | Reading it back | Verified | Rolled back. Nothing changed. |
| 6 | Reopen Work and Client | Opening… | Reopened | Couldn't reopen Client. **Open Client** (the move itself is done). |

Glyphs: pending `circle` tertiary, running a small spinner, done `checkmark.circle.fill`, failed `xmark.octagon.fill`. Steps 1 and 2 can be cancelled (**Stop**, ⌘.). From step 3 the button reads "Finishing…" and is disabled; a move is never left half-done.

### Outcomes

| Outcome | What the user sees |
|---|---|
| Success | Sheet closes after 0.6 s on all-green. The row animates out of the source list; the destination account row pulses once and its count ticks up. Toast: **Moved "Refactor payment retry logic" to Client · Team account.** [Undo] [Show]. |
| Failure before files moved | Sheet stays, failed step red, others gray. **Nothing changed.** [Try Again] [Close]. Apps that were quit are reopened. |
| Failure after files moved | Automatic rollback from the backup, then: **Move rolled back. Nothing changed.** [Show Log] [Close]. |
| Crash or power loss mid-move | On next launch, before the window shows anything else: sheet **Finish an interrupted move?** with the journal step reached. [Finish Move] (default) [Roll Back]. |
| Partial (2 of 3) | Toast: **Moved 2 sessions to Client. 1 skipped: busy.** [Undo] [Show]. |

### Open a copy (secondary path)

Reached by Option-drag, **Move To ▸ Open a Copy In ▸**, or ⌥⇧⌘M. Uses Claude's own deep link, so it works while apps run.

Sheet title: **Open a copy in Client · Team account**. Body lists what comes and what doesn't:

| Comes along | Stays behind |
|---|---|
| Title, full history | PR links, branch and worktree, sidebar group |

Folder check: if the folder is gone, warn **The copy will ask for a different folder.** Footer: **The original stays in Work. Don't run both at once.** Button: **Open Copy**. The source row gets a "Copied" chip; the new instance comes to the front with the session open.

---

## 6. History and Undo

### Undo (⌘Z)

- Undoes the most recent move or copy from this window, as long as the toast is showing or nothing else has been moved since (Edit ▸ Undo Move "Refactor payment…").
- An undo is a move in reverse, so it runs the same checks and quit-and-reopen steps, in a compact progress toast rather than a sheet: **Restoring "Refactor payment…"** → **Restored to Work · you@example.com.**
- If the restore would hit a block (the session is now busy in Client), Undo opens the full sheet with the block shown.
- Undo for a copy archives the copy in the destination; it never deletes it.

### History view

Sidebar ▸ History (⌘Y). A table, newest first.

| Column | Example |
|---|---|
| When | Today 14:02 |
| Sessions | "Refactor payment retry logic" · or "3 sessions" (disclosure) |
| From → To | Work · you@example.com → Client · Team account |
| Kind | Move · Copy · Restore |
| Result | Done · Restored · Rolled back · Needs attention |
| Action | **Restore** · **Archive Copy** · (none) |

**Restore** puts every file the move touched back as it was before the move (session entry, worktree leases, archive index), from the journal's backup, through the same Move sheet with checks: apps must quit, the session must not be busy at its current location, and the source must not hold a newer entry with that id. Activity since the move is never lost, because history is shared: the sheet says **Anything said since the move stays. History isn't part of the restore.**

Footer: backup size ("12 moves · 184 KB of backups") and **Empty History…** (confirmation: "Empty History? Restore won't be possible for these 12 moves. The sessions stay where they are.").

A move whose journal is unfinished shows **Needs attention** with [Finish] [Roll Back], and badges the History row in the sidebar.

---

## 7. First run and empty states

### First run

1. **Find instances** (window opens straight into this, no splash). Title: **Finding Claude on this Mac.** Rows appear as found, each with tile, name and session count: Claude 310 · Work 86 · Client 28 · Lab 0. Under 1 s typical. Button: **Continue**.
2. **Name your accounts.** Title: **Which accounts are these?** Subtitle: **Claude stores account IDs, not emails. Name each one once.**
   One card per account id:
   - ID tail in mono: `eb90b3bb`
   - Where it's signed in now: **Signed in to Claude now** (or **Not signed in anywhere now**)
   - Sessions: **310 in Claude, 82 in Work**
   - Three recent titles, so the user recognises it: "main:planning-Playable design research…", "Fix export filter…"
   - Text field, placeholder **Name or email**
   - Link: **Check in Work** (brings that instance forward; its Settings ▸ Account shows the email)
   Buttons: **Skip for Now** · **Done** (default). Skipped accounts show their ID tail (`eb90b3bb`) with a **Name…** button in the sidebar.
3. Main window, scoped to **Hidden in Their App** if it has sessions, with a one-time callout on the sidebar row: **82 sessions are hidden because Work is signed in to Team account. Drag them to an account that's signed in to see them again.**

Rename later: select an account row and press Return, or **Name…** in its context menu.

### Empty and error states

| State | Where | Copy | Actions |
|---|---|---|---|
| No Claude Profiles (only the original app) | Sidebar footer note | **Only one instance found.** Instances you make with Claude Profiles show up here. | (none) |
| Only one account anywhere | Move To menu | **No other account to move to.** Sign in to another account in Claude, or make an instance with Claude Profiles. | (none) |
| Instance with no sessions (Lab) | List | **No Code sessions in Lab.** Drag sessions here to move them. | Open Lab |
| Filter with nothing | List | **No archived sessions in this account.** | Show All |
| Search with nothing | List | **No results for "regex" in this account.** | Search All Instances |
| Instance unreadable | List + sidebar glyph | **Can't read Work's sessions.** The folder ~/.claude-profiles/work/… is missing. | Show in Finder · Scan Again |
| Some files unreadable | Banner over list | **2 session files couldn't be read and aren't shown.** | Show Files |
| Version not verified | Banner over list | **Work 4.31.0 is newer than Session Mover has checked. Moves in and out of it use Open a Copy until Session Mover is updated.** | Check for Updates |
| Claude not found at all | Window | **Claude isn't installed.** Session Mover works with the Claude desktop app. | Get Claude |

---

## 8. Microcopy

Voice: plain, direct, active. Name the app and the account in every string that moves something. No "please", no "sorry", no "successfully", no em-dash asides. Title Case for buttons and menu items (macOS), sentence case for everything else.

### Buttons and menu items

| Context | String |
|---|---|
| Row context menu | Move To ▸ · Open a Copy In ▸ · Open in Work · Reveal in Finder · Copy Session ID |
| Move To submenu item | Client ▸ Team account (Signed In) |
| Move To submenu, disabled item | Work ▸ you@example.com (Current) |
| Sheet default | Move · Quit & Move · Move 2, Skip 1 · Replace · Open Copy |
| Sheet secondary | Cancel · Open a Copy Instead · Show Files · Stop |
| Progress | Finishing… |
| Failure | Try Again · Show Work · Show Log · Close |
| Recovery | Finish Move · Roll Back |
| History | Restore · Archive Copy · Empty History… |
| Account | Name… · Check in Work · Skip for Now · Done |

### Sheet titles

| Case | Title |
|---|---|
| One session | Move "Refactor payment retry logic" |
| Several | Move 3 Sessions |
| Copy | Open a Copy in Client · Team account |
| Restore | Restore "Refactor payment retry logic" |
| Interrupted | Finish an interrupted move? |
| Empty History | Empty History? |

### Check rows (pass / warn / block)

| Check | String |
|---|---|
| Not running | Session isn't running |
| Open, idle | Open in Work. Quitting closes it. |
| Busy | "Data import validation…" is busy. Wait for the turn to finish, or stop it in Claude. |
| Busy app | Claude has a busy session, "Data import validation…", so it can't quit now. |
| Apps quit | Work and Client are open. They quit, then reopen. |
| No quit needed | No apps need to quit |
| Folder ok | Working folder exists |
| Folder missing | Folder is missing. The session will ask for a different folder. |
| Lease | Worktree lease moves with it |
| No lease | No worktree |
| Org same | Same organization |
| Org different | Different organization. Connectors, published artifacts and scheduled tasks stay behind. |
| Duplicate | Already in Client · Team account |
| New at destination | Not in Client yet |
| Limit notice | The weekly-limit notice is cleared on move. |
| History note | History comes along. Conversations live in ~/.claude/projects, which every instance reads. This move doesn't touch them. |

### Toasts

| Event | String | Buttons |
|---|---|---|
| Moved one | Moved "Refactor payment retry logic" to Client · Team account. | Undo · Show |
| Moved several | Moved 3 sessions to Client · Team account. | Undo · Show |
| Partial | Moved 2 sessions. 1 skipped: busy. | Undo · Show |
| Copy | Opened a copy in Client. | Show |
| Undo running | Restoring "Refactor payment…" | (none) |
| Undo done | Restored to Work · you@example.com. | (none) |
| Rolled back | Move rolled back. Nothing changed. | Show Log |
| Labelled | Named eb90b3bb "you@example.com". | Undo |

### Errors

| Case | String |
|---|---|
| App won't quit | Work didn't quit. It may be showing a dialog. |
| Can't reopen | Couldn't reopen Client. The move is done. |
| Write failed | Couldn't write to Client's folder. Nothing changed. |
| Disk full | Not enough space for the backup. Nothing changed. |
| Unreadable file | local_9d4d….json isn't valid. It's left as it is. |

---

## 9. Keyboard and accessibility

### Shortcuts

| Action | Keys |
|---|---|
| Move To… (destination picker, type to filter) | ⇧⌘M |
| Open a Copy In… | ⌥⇧⌘M |
| Undo / Redo move | ⌘Z / ⇧⌘Z |
| History | ⌘Y |
| Search | ⌘F |
| Filter: Active · Archived · Running · Errors · All | ⌘1 · ⌘2 · ⌘3 · ⌘4 · ⌘0 |
| Group by Project | ⌃⌘G |
| Open in its app | ⌘O |
| Reveal in Finder | ⇧⌘R |
| Rescan | ⌘R |
| Toggle sidebar / inspector | ⌃⌘S / ⌥⌘I |
| Rename account label | Return on an account row |
| Select all, extend, add | ⌘A, ⇧↑/↓, ⌘-click |
| Move focus between panes | Tab / ⇧Tab |
| Sheet: confirm / cancel / stop | Return / Esc / ⌘. |
| During drag: copy instead of move | hold ⌥ |
| During drag: spring-open now | Space |

### VoiceOver

| Element | Label | Value / hint |
|---|---|---|
| Instance row | "Work, instance, running" | "2 accounts, 86 sessions" |
| Account row | "you@example.com, account in Work, not signed in" | "82 sessions, hidden in Work" |
| Account row as drop target | "Drop to move 2 sessions to Client, Team account" | announced on drag enter |
| Invalid target | "Can't drop here. Already in Work, you@example.com" | |
| Session row | "Trip data validation and VIN auto-population. web-app, branch claude/vin-autofill. Busy. 2 minutes ago. 3 pull requests." | custom actions: Move To, Open a Copy In, Open in Claude, Reveal in Finder |
| Check row | "Warning: Different organization. Connectors, published artifacts and scheduled tasks stay behind." | |
| Progress step | "Step 3 of 6, Move session file, done" | announcements on each step change |

Drag and drop always has the Move To route; VoiceOver users never need to drag. Every chip has a full-sentence label (section 3). Contrast: chip text 4.5:1 on its fill in both appearances; status glyphs pair with text.

### Reduced motion and transparency

| Setting | Change |
|---|---|
| Reduce Motion | No spring-load blink, no row slide-out (cross-fade), no destination pulse, busy glyph static, progress steps switch without animation, toast fades. |
| Reduce Transparency | Sidebar and drag badge use opaque window background. |
| Increase Contrast | Chips gain a 1 pt border; drop highlight ring 2 pt. |
| Larger text (Dynamic Type sizes in macOS 14) | Row height grows; line 2 wraps chips to the right of the title, never truncates the title to nothing. |

---

## 10. Visual direction

- **Native first.** SwiftUI `NavigationSplitView`, sidebar list style with `.sidebar` material (vibrancy), unified compact toolbar, `.inspector` pane, sheets for anything that changes files. AppKit `NSOutlineView` bridge only where SwiftUI falls short (spring-loaded drop targets, drag pile previews).
- **Type.** SF Pro (system font) at macOS sizes: 13 regular body, 11 secondary, 15 semibold inspector title, 11 medium chips. SF Mono 11 for branches, IDs and paths. Tabular figures for every date, time and count.
- **Colour.** The system accent colour drives selection, focus and drop highlights, following the user's setting. Instance accents appear only inside instance tiles and the 3 pt leading stripe on the inspector's header, so a blue selection never fights a blue Work tile. Status colours are system semantic: green, yellow, orange, red, secondary gray.
- **Symbols.** SF Symbols, hierarchical rendering, weight matching the adjacent text. Instance symbols come from Claude Profiles' registry unchanged.
- **Light and dark.** All colours from semantic system colours and asset-catalogue pairs; chip fills are the status colour at 14 % (light) / 22 % (dark) with full-strength text.
- **Density.** 28 pt sidebar rows, 52 pt session rows, 8 pt grid. Inspector sections separated by hairline dividers, label column 96 pt right-aligned in secondary text, macOS Get Info style.
- **Motion.** Short and physical: 180 ms ease-out for highlights, 250 ms for row removal, spring for the drop pulse. Nothing loops except the busy indicator.
- **Distribution.** Not sandboxed (it reads other apps' data folders), Developer ID signed and notarized, macOS 14+.

---

## Open questions found in the facts

1. **Running vs idle-open.** "A running session must never be moved" and "warn when sessions are idle but open" read as conflicting for the session being moved. This spec treats an idle session open in an app that will quit as a warning (quitting ends the process), a busy one as a block, and one held by a process outside the instances (a Terminal `claude`) as a block.
2. **Which account is signed in where.** The facts don't say which Work account is current or which accounts the other instances use. The mockup assumes Work is signed in to Team account (after the limit on you@example.com), Client to Team account, Claude to you@example.com, and Lab to an unnamed account.
3. **Account identity across instances.** Labels are stored per account UUID, so one label covers that account in every instance. If the same account has different UUIDs per instance, labelling has to happen per instance.
4. **Organizations.** Whether any account here has more than one organization is not stated; the third sidebar level is hidden unless one does.
5. **"Same session at destination".** By entry id it is a block with Replace. After an Open a Copy, the copy has a new id but the same history; this spec flags that as a warning ("A copy of this session is already in Client"), not a block.
6. **Sidebar groups and pins.** The facts say the deep-link copy loses the sidebar group, implying a full move keeps it, but where groups are stored is unconfirmed. The sheet should not promise groups until that is known.
7. **Dropping on an instance row** when it has several accounts: this spec targets the signed-in account. An alternative is to refuse and require an account row.
8. **Undo after use.** If the moved session ran in the destination before Undo, history is safe (shared), but the destination entry's newer fields (title edits, PRs added) would be replaced by the backup. Restore should warn when the destination entry changed since the move.
