#!/bin/sh
set -eu

stiff_root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
source_dir="$stiff_root/examples/kingdom-comparison/bend"
build_dir="$stiff_root/.cache/kingdom-comparison/bend"
binary="$build_dir/kingdom"
tests="$build_dir/tests"

mkdir -p "$build_dir"
verdict=$("$stiff_root/.cache/toolchain/bin/bend" "$source_dir/PROOF.bend" --check-only)
echo "$verdict"
case "$verdict" in
  *"ALL PROOFS CHECK"*) ;;
  *) echo "Expected passing Bend proof verdict." >&2; exit 1 ;;
esac
"$stiff_root/scripts/build-native.sh" "$source_dir/tests.bend" "$tests"
"$tests"
"$stiff_root/scripts/build-native.sh" "$source_dir/main.bend" "$binary"

actual=$("$binary" mortgage0 pass1 repay0 buy1)
expected='ok 25 20 95 0 1 1
ok 25 20 95 0 1 0
ok 20 20 100 0 0 1
ok 30 10 100 1 0 0'
[ "$actual" = "$expected" ] || {
  echo 'CLI accepted-sequence output mismatch' >&2
  exit 1
}

actual=$("$binary" buy0 nope pass1 Buy0)
expected='error 20 20 100 0 0 0
error 20 20 100 0 0 0
error 20 20 100 0 0 0
error 20 20 100 0 0 0'
[ "$actual" = "$expected" ] || {
  echo 'CLI rejection output mismatch' >&2
  exit 1
}

actual=$("$binary")
[ -z "$actual" ] || {
  echo 'CLI with no arguments produced output' >&2
  exit 1
}

echo 'all Bend kingdom checks passed'
