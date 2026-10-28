#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ "${1:-}" == gui ]]; then
    Scripts/build-app.sh debug
    open "$PWD/dist/Dial Studio.app"
else
    swift build
    if [[ "${1:-}" == hidd ]]; then
        shift
        exec sudo "$PWD/.build/debug/ulanzid" hidd "$@"
    fi
    exec "$PWD/.build/debug/ulanzid" "$@"
fi
