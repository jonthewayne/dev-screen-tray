#!/bin/zsh
set -eu

ROOT=${0:A:h:h}
CTL="$ROOT/dev-screen-ctl"
MOCK_SSH="$ROOT/tests/mock-ssh.zsh"
MOCK_NETSTAT="$ROOT/tests/mock-netstat.zsh"
MOCK_PMSET="$ROOT/tests/mock-pmset.zsh"
TEST_TMP=$(mktemp -d /tmp/dev-screen-ctl-tests.XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT
LOG="$TEST_TMP/ssh.log"
PMSET_LOG="$TEST_TMP/pmset.log"
NETSTAT_LOG="$TEST_TMP/netstat.log"
touch "$LOG"
touch "$PMSET_LOG"
touch "$NETSTAT_LOG"

fail() {
  print -u2 "FAIL: $1"
  exit 1
}

run_ctl() {
  DEV_SCREEN_SSH_BIN="$MOCK_SSH" \
  DEV_SCREEN_NETSTAT_BIN="$MOCK_NETSTAT" \
  DEV_SCREEN_LOCAL_VIEWERS_TIMEOUT=1 \
  DEV_SCREEN_PMSET_BIN="$MOCK_PMSET" \
  DEV_SCREEN_TEST_LOG="$LOG" \
  DEV_SCREEN_NETSTAT_TEST_LOG="$NETSTAT_LOG" \
  DEV_SCREEN_PMSET_TEST_LOG="$PMSET_LOG" \
  XDG_CONFIG_HOME="$TEST_TMP/config" \
  DEV_USER=tester \
  DEV_IP=100.64.0.2 \
  "$CTL" "$@"
}

brightness=$(MOCK_BRIGHTNESS=0.75 run_ctl brightness)
[[ "$brightness" == "0.75" ]] || fail "brightness must return a numeric readback"

if MOCK_SSH_EXIT=7 run_ctl black >/dev/null 2>&1; then
  fail "black must propagate an SSH failure"
fi

if MOCK_SSH_EXIT=7 run_ctl restore 0.42 >/dev/null 2>&1; then
  fail "restore must propagate an SSH failure"
fi

before_invalid=$(wc -l < "$LOG")
if run_ctl restore 2 >/dev/null 2>&1; then
  fail "restore must reject brightness outside the 0...1 range"
fi
after_invalid=$(wc -l < "$LOG")
[[ "$before_invalid" == "$after_invalid" ]] || fail "invalid restore input must not reach SSH"

run_ctl restore 0.42 >/dev/null
[[ "$(tail -1 "$LOG")" == *"/usr/local/bin/brightness 0.42"* ]] || fail "restore must use the requested prior brightness"

disconnect_output=$(run_ctl disconnect)
disconnect_command=$(tail -1 "$LOG")
[[ "$disconnect_command" == *"/usr/local/bin/brightness 0;"*"pmset displaysleepnow"* ]] ||
  fail "disconnect must black the display before requesting display sleep"
[[ "$disconnect_output" == "black_status=0 sleep_status=0" ]] ||
  fail "disconnect must report both remote operation statuses"

if MOCK_SSH_EXIT=7 run_ctl disconnect >/dev/null 2>&1; then
  fail "disconnect must propagate an SSH failure"
fi

if partial_output=$(MOCK_SLEEP_STATUS=1 run_ctl disconnect 2>/dev/null); then
  fail "disconnect must fail when display sleep fails"
fi
[[ "$partial_output" == "black_status=0 sleep_status=1" ]] ||
  fail "disconnect must preserve a successful blackout when display sleep fails"

start_seconds=$SECONDS
if DEV_SCREEN_SSH_TIMEOUT=1 MOCK_SSH_HANG=1 run_ctl black >/dev/null 2>&1; then
  fail "black must fail when the SSH command exceeds its deadline"
fi
(( SECONDS - start_seconds < 3 )) || fail "SSH command deadline must bound a hung display request"

[[ "$(MOCK_VIEWERS=0 run_ctl local-viewers)" == "0" ]] ||
  fail "local-viewers must report no incoming screen-sharing sessions"
[[ "$(MOCK_VIEWERS=1 run_ctl local-viewers)" == "1" ]] ||
  fail "local-viewers must report one incoming screen-sharing session"
[[ "$(MOCK_VIEWERS=2 run_ctl local-viewers)" == "2" ]] ||
  fail "local-viewers must count each established incoming session"
[[ "$(tail -1 "$NETSTAT_LOG")" == "-an -p tcp" ]] ||
  fail "local-viewers must request macOS TCP connection state"

if MOCK_NETSTAT_EXIT=7 run_ctl local-viewers >/dev/null 2>&1; then
  fail "local-viewers must propagate a netstat failure"
fi

start_seconds=$SECONDS
if MOCK_NETSTAT_HANG=1 run_ctl local-viewers >/dev/null 2>&1; then
  fail "local-viewers must fail when netstat exceeds its deadline"
fi
(( SECONDS - start_seconds < 3 )) || fail "local viewer probe deadline must bound a hung netstat"

run_ctl local-sleep
[[ "$(tail -1 "$PMSET_LOG")" == "displaysleepnow" ]] ||
  fail "local-sleep must ask macOS to sleep this Mac's display"

if MOCK_PMSET_EXIT=1 run_ctl local-sleep >/dev/null 2>&1; then
  fail "local-sleep must propagate a pmset failure"
fi

print "dev-screen-ctl contract tests passed"
