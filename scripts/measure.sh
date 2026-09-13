#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Houston.app"
PID=${1:-$(pgrep -nx Houston || true)}
if [[ -z "$PID" ]]; then
    echo "Open dist/Houston.app first, then run this script."
    exit 1
fi
du -sh "$APP"
ps -p "$PID" -o pid=,rss=,etime=,comm=
echo "30-second sample: MEM is macOS footprint; ps RSS above is in KiB. Ignore the first CPU sample."
top -l 16 -s 2 -pid "$PID" -stats pid,command,cpu,mem,threads,idlew,power | awk '/^PID|Houston/'
