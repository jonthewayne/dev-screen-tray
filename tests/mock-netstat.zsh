#!/bin/zsh
set -eu

[[ -n "${DEV_SCREEN_NETSTAT_TEST_LOG:-}" ]] && print -r -- "$*" >> "$DEV_SCREEN_NETSTAT_TEST_LOG"

[[ "${MOCK_NETSTAT_HANG:-0}" == "1" ]] && exec sleep 30
[[ "${MOCK_NETSTAT_EXIT:-0}" == "0" ]] || exit "$MOCK_NETSTAT_EXIT"

print "Active Internet connections (including servers)"
print "Proto Recv-Q Send-Q  Local Address  Foreign Address  (state)"
print "tcp46 0 0 *.5900 *.* LISTEN"

case "${MOCK_VIEWERS:-0}" in
  0) ;;
  1)
    print "tcp4 0 0 100.64.0.1.5900 100.64.0.2.50100 ESTABLISHED"
    ;;
  2)
    print "tcp4 0 0 100.64.0.1.5900 100.64.0.2.50100 ESTABLISHED"
    print "tcp6 0 0 fe80::1.5900 fe80::2.50101 ESTABLISHED"
    ;;
  *)
    print -u2 "unsupported mock viewer count"
    exit 2
    ;;
esac

# These must not count as active incoming viewers.
print "tcp4 0 0 100.64.0.1.5900 100.64.0.3.50102 CLOSE_WAIT"
print "tcp4 0 0 100.64.0.1.50103 100.64.0.3.5900 ESTABLISHED"
