#!/bin/zsh
# Phase 2 live test: round trips test1 <-> test2 with smctl, verified by spike/verify.sh
set -u
R=/Users/me/code/claude-session-mover; B=$R/.build/debug/smctl
quitc() { osascript -e "tell application id \"com.anthropic.claudefordesktop-$1\" to quit" >/dev/null 2>&1
  t=0; while pgrep -f "Claude-$1.app/Contents/MacOS/$1.real" >/dev/null && (( t < 90 )); do sleep 1; ((t++)); done
  pgrep -f "Claude-$1.app/Contents/MacOS/$1.real" >/dev/null && { echo "QUIT FAILED $1"; exit 1; }; sleep 2; }
sid=${1:-local_e66a5d02-1e36-460c-af2e-0652cc98ddda}
for i in 1 2 3; do
  echo "=== run $i: test1 -> test2"
  $B move $sid --to test2 || exit 1
  zsh $R/spike/verify.sh test2 $sid test1 | tail -4; quitc test2
  echo "=== run $i: test2 -> test1"
  $B move $sid --to test1 || exit 1
  zsh $R/spike/verify.sh test1 $sid test2 | tail -4; quitc test1
done
