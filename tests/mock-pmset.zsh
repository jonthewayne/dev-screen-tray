#!/bin/zsh
set -eu

print -r -- "$*" >> "$DEV_SCREEN_PMSET_TEST_LOG"
[[ "${MOCK_PMSET_HANG:-0}" == "1" ]] && exec sleep 30
exit "${MOCK_PMSET_EXIT:-0}"
