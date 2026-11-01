#!/bin/zsh
# Phase 3 live test on test1/test2 only
set -u
R=/Users/me/code/claude-session-mover; B=$R/.build/debug/smctl; LOG=~/Library/Logs/Claude/main.log
running() { pgrep -f "Claude-$1.app/Contents/MacOS/$1.real" >/dev/null; }
openc() { open -b com.anthropic.claudefordesktop-$1; t=0; until running $1 || (( t>30 )); do sleep 1; ((t++)); done; sleep 12; }
sid=local_2861dab1-7d93-42c2-a52a-99e99e3e9502
echo "### A. orchestrated move with both copies running"
openc test1; openc test2; running test1 && running test2 && echo "both running"
$B move $sid --to test2 --quit | grep -E "warn|BLOCK|done|Moved|move id"; echo exit=$?
sleep 15; running test1 && running test2 && echo "both reopened"
zsh $R/spike/verify.sh test2 $sid test1 | tail -3
echo "### A2. and back"
$B move $sid --to test1 --quit | grep -E "BLOCK|Moved"; sleep 15
zsh $R/spike/verify.sh test1 $sid test2 | tail -3
echo "### B. kill at lease, then finish"
SM_TEST_CRASH_AT=lease $B move $sid --to test2 --quit >/dev/null; echo crash-exit=$?
$B recover
mid=$($B recover | grep -o '20[0-9]*-[0-9]*-[0-9a-f]\{6\}' | head -1); echo mid=$mid
$B recover $mid --finish | tail -2; sleep 15
zsh $R/spike/verify.sh test2 $sid test1 | tail -3
echo "### C. kill at writeDestination, then roll back (byte compare)"
snap() { (cd ~/.claude-profiles && find test1/Library/Application\ Support/Claude/claude-code-sessions test2/Library/Application\ Support/Claude/claude-code-sessions -type f -exec shasum {} \; ; shasum test*/Library/Application\ Support/Claude/{git-worktrees.json,claude_desktop_config.json} 2>/dev/null) | sort; }
$B move $sid --to test1 --quit --no-reopen | grep -E "BLOCK|Moved"   # get copies quit and stable
snap > $0.before
SM_TEST_CRASH_AT=writeDestination $B move $sid --to test2 --quit --no-reopen >/dev/null; echo crash-exit=$?
mid=$($B recover | grep -o '20[0-9]*-[0-9]*-[0-9a-f]\{6\}' | head -1); echo mid=$mid
$B recover $mid --roll-back --no-reopen | tail -2
snap > $0.after; diff $0.before $0.after >/dev/null && echo "ROLLBACK BYTE-FOR-BYTE: IDENTICAL" || echo "ROLLBACK DIFFERS"; rm -f $0.before $0.after
echo "### D. open a copy (apps running), then archive the copy"
openc test1; openc test2
$B copy $sid --to test2 | tail -3; sleep 8
start=$(( $(wc -l < $LOG) - 400 )); tail -n +$start $LOG | grep -o "Imported CLI session ${sid#local_} as local_[0-9a-f-]*" | tail -1
mid=$($B history | grep -o '20[0-9]*-[0-9]*-[0-9a-f]\{6\}' | head -1)
$B undo $mid --quit | tail -3
