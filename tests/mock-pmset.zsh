#!/bin/zsh
set -eu

print -r -- "$*" >> "$DEV_SCREEN_PMSET_TEST_LOG"
exit "${MOCK_PMSET_EXIT:-0}"
