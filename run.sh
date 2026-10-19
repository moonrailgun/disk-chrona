#!/bin/sh
# Dev one-step start: debug-build DiskChrona.app, stop any running copy, launch the new one.
set -e
cd "$(dirname "$0")"
./build-app.sh debug
pkill -x DiskChrona || true
while pgrep -x DiskChrona >/dev/null; do sleep 0.1; done
open -n build/DiskChrona.app   # -n: no race with the copy that is still unregistering
