#!/bin/zsh
set -eu

remote_command="${@: -1}"
print -r -- "$remote_command" >> "$DEV_SCREEN_TEST_LOG"

if (( ${MOCK_SSH_HANG:-0} != 0 )); then
  while true; do :; done
fi

if (( ${MOCK_SSH_EXIT:-0} != 0 )); then
  exit "$MOCK_SSH_EXIT"
fi

if [[ "$remote_command" == *"/usr/local/bin/brightness -l"* ]]; then
  print "display 0: brightness ${MOCK_BRIGHTNESS:-0.75}"
fi

if [[ "$remote_command" == *"black_status="*"sleep_status="* ]]; then
  black_status=${MOCK_BLACK_STATUS:-0}
  sleep_status=${MOCK_SLEEP_STATUS:-0}
  print "black_status=$black_status sleep_status=$sleep_status"
  (( black_status == 0 && sleep_status == 0 ))
fi
