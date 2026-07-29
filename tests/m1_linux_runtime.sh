#!/usr/bin/env bash
#
# M1 acceptance test (milestones/M1-linux-runtime.md) — drives the real
# omnia CLI against the real vmd + Linux guest. No mocks; this script IS
# the milestone's definition of done.
#
# Prerequisites (see BUILDING.md):
#   - guest image installed at ~/Library/Application Support/Omnia/linux/
#     (rootfs.img, vmlinuz, initramfs.img — tools/build-linux-image/build-in-vm.sh)
#   - vmd built, signed with vmd/vmd.entitlements, registered as the
#     com.omnia.vmd LaunchAgent
#   - cli built (cli/.build/debug/omnia)
#
# The guest is treated as disposable; this writes marker files into it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OMNIA="${OMNIA:-$REPO_ROOT/cli/.build/debug/omnia}"
SUPPORT_DIR="$HOME/Library/Application Support/Omnia"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

linux_state() { "$OMNIA" status 2>/dev/null | awk -F': ' '/^linux:/ {print $2}'; }

# Guest commands run in a PTY, so their output arrives CRLF — normalize.
run_linux() { "$OMNIA" linux "$@" 2>/dev/null | tr -d '\r'; }

# Poll every 5s for up to $2 seconds until linux state == $1.
wait_for_state() {
  local want="$1" timeout="${2:-120}" waited=0
  while (( waited < timeout )); do
    [[ "$(linux_state)" == "$want" ]] && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

echo "== M1 acceptance: resetting to a cold state =="
launchctl kickstart -k "gui/$(id -u)/com.omnia.vmd"
rm -f "$SUPPORT_DIR/linux/snapshot.vzstate"
sleep 2

echo "== 1. stopped before first use =="
state="$(linux_state)"
[[ "$state" == "stopped" ]] && ok "initial state is stopped" \
  || fail "initial state is '$state', wanted 'stopped'"

echo "== 2. omnia linux echo hi (cold boot) =="
out="$(run_linux echo hi)"
[[ "$out" == "hi" ]] && ok "echo hi returned '$out'" \
  || fail "echo hi returned '$out'"

state="$(linux_state)"
[[ "$state" == "running" ]] && ok "running after first command" \
  || fail "state after first command is '$state', wanted 'running'"

echo "== 3. exit code propagation =="
"$OMNIA" linux sh -c 'exit 42' >/dev/null 2>&1
code=$?
[[ "$code" == "42" ]] && ok "guest exit code 42 propagated" \
  || fail "guest exit 42 came back as $code"

echo "== 4. marker file for true-resume proof =="
marker_before="$(run_linux sh -c 'echo omnia-m1 > /root/omnia-marker && sync && stat -c "%Y %s" /root/omnia-marker && cat /root/omnia-marker')"
[[ -n "$marker_before" ]] && ok "marker written: $marker_before" \
  || fail "could not write marker in guest"

echo "== 5. idle-suspend within ~90s of last session closing (poll 5s, max 150s) =="
if wait_for_state suspended 150; then
  ok "guest reached suspended"
else
  fail "guest never reached suspended (state: $(linux_state))"
fi

echo "== 6. no VM process while suspended =="
if pgrep -qf 'com.apple.Virtualization.VirtualMachine'; then
  fail "Virtualization helper process still running while suspended"
else
  ok "no Virtualization VM process while suspended"
fi

echo "== 7. resume via omnia linux uname -a (wall clock) =="
start_ns=$(date +%s)
out="$(run_linux uname -a)"
elapsed=$(( $(date +%s) - start_ns ))
if [[ "$out" == Linux\ omnia-linux* ]]; then
  ok "uname from suspended returned in ${elapsed}s: $out"
  (( elapsed <= 10 )) || fail "resume+command took ${elapsed}s (>10s; target ~5s)"
else
  fail "uname from suspended returned '$out'"
fi

echo "== 8. marker unchanged after resume (same mtime+size+content) =="
marker_after="$(run_linux sh -c 'stat -c "%Y %s" /root/omnia-marker && cat /root/omnia-marker')"
[[ "$marker_after" == "$marker_before" ]] && ok "marker identical across suspend/resume" \
  || fail "marker changed: before='$marker_before' after='$marker_after'"

echo
echo "== Result: $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
