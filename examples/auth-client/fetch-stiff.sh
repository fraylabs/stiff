#!/bin/sh
set -eu
cd "$(dirname "$0")"
stiff_revision=$(cat stiff.rev)
case "$stiff_revision" in ''|*[!0-9a-f]*) echo 'stiff.rev must contain a full lowercase Git commit ID.' >&2; exit 1;; esac
[ "${#stiff_revision}" -eq 40 ] || { echo 'stiff.rev must contain 40 hex digits.' >&2; exit 1; }
[ ! -e deps/stiff ] || { echo 'deps/stiff exists; inspect it before changing dependencies.' >&2; exit 1; }
mkdir -p deps
stiff_temp=$(mktemp -d deps/stiff-fetch.XXXXXX)
trap 'rm -rf "$stiff_temp"' EXIT HUP INT TERM
git -C "$stiff_temp" init -q
git -C "$stiff_temp" remote add origin https://github.com/fraylabs/stiff.git
git -C "$stiff_temp" fetch --depth=1 origin "$stiff_revision"
git -C "$stiff_temp" checkout -q --detach FETCH_HEAD
[ "$(git -C "$stiff_temp" rev-parse HEAD)" = "$stiff_revision" ] || exit 1
mv "$stiff_temp" deps/stiff
