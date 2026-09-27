#!/bin/sh
# Live pages in hidden WebKit views, uBO's default lists off and on: requests
# per host, pop-up attempts after real clicks, frames given scriptlets, and
# the cost of a full style recalculation. No window is shown.
#   Tests/blocker-pages/run.sh https://ww4.seeflix.to/heart-of-the-beast/ https://animekhor.org/
# Writes $OUT (default .local-resolution/evidence/blocker-pages-<time>.json).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LISTS=${LISTS:-$(mktemp -d)}
fetch() { [ -s "$LISTS/$1" ] || curl -sfL "$2" -o "$LISTS/$1"; }
fetch filters.min.txt https://ublockorigin.github.io/uAssets/filters/filters.min.txt
fetch badware.min.txt https://ublockorigin.github.io/uAssets/filters/badware.min.txt
fetch quick-fixes.min.txt https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt
fetch unbreak.min.txt https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt
fetch easylist.txt https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt
fetch serverlist.phppgl.txt 'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext'
fetch easyprivacy.txt https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt
fetch privacy.min.txt https://ublockorigin.github.io/uAssets/filters/privacy.min.txt
fetch urlhaus-filter-ag-online.txt https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-ag-online.txt
BIN=$(mktemp -d)/blocker-pages
xcrun swiftc -O "$ROOT/Tests/blocker-pages/main.swift" "$ROOT/Sources/Search/FilterCompiler.swift" "$ROOT/Sources/Search/Scriptlets.swift" -o "$BIN"
mkdir -p "$ROOT/.local-resolution/evidence"
LISTS="$LISTS" OUT=${OUT:-$ROOT/.local-resolution/evidence/blocker-pages-$(date +%Y%m%d-%H%M%S).json} "$BIN" "$@"
