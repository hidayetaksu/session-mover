#!/bin/zsh
# verify.sh <dest copy slug> <local_id> [<source copy slug>]
# Opens the destination copy, focuses the session through the resume deep link and checks Claude's log:
# "already imported as local_<id>" proves the copy loaded the moved entry (a fresh import would say "Imported CLI session").
# Then checks the source copy has not written the entry back.
set -u
dst=$1; sid=$2; src=${3:-}
cli=${sid#local_}
data() { [[ $1 == default ]] && print "$HOME/Library/Application Support/Claude" || print "$HOME/.claude-profiles/$1/Library/Application Support/Claude"; }
bundle() { [[ $1 == default ]] && print com.anthropic.claudefordesktop || print com.anthropic.claudefordesktop-$1; }
LOG=~/Library/Logs/Claude/main.log
start=$(( $(wc -l < $LOG) + 1 ))

if ! pgrep -f "/Applications/Claude-$dst.app/Contents/MacOS/$dst.real" >/dev/null; then
  open -b $(bundle $dst)
  t=0; until tail -n +$start $LOG | grep -q 'CCD-SessionRecovery\] Probe' || (( t >= 60 )); do sleep 1; (( t++ )); done
fi
open -b $(bundle $dst) "claude://resume?session=$cli"
t=0; until tail -n +$start $LOG | grep -q "Warming session $sid\|Imported CLI session $cli\|already imported as $sid" || (( t >= 30 )); do sleep 1; (( t++ )); done
sleep 3
ok=1
tail -n +$start $LOG | grep -q "already imported as $sid" && echo "PASS loaded moved entry in $dst" || { echo "FAIL $dst did not load $sid from disk"; ok=0; }
tail -n +$start $LOG | grep -q "Imported CLI session $cli as" && { echo "FAIL $dst re-imported it (entry was not loaded)"; ok=0; }
tail -n +$start $LOG | grep -q "Session $sid warmed successfully" && echo "PASS session warmed" || { echo "WARN no warm line"; }
tail -n +$start $LOG | grep -i "$sid" | grep -i -E 'error|fail' | head -5
if [[ -n $src ]]; then
  if [[ -n $(find "$(data $src)/claude-code-sessions" -name "$sid.json") ]]; then echo "FAIL source $src still has $sid"; ok=0; else echo "PASS source $src has no entry"; fi
fi
(( ok )) && echo RESULT PASS || echo RESULT FAIL
