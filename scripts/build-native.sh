#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
  echo 'Usage: scripts/build-native.sh program.bend output' >&2
  exit 2
fi
stiff_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
stiff_default=bend
if [ -x "$stiff_root/.cache/toolchain/bin/bend" ]; then
  stiff_default="$stiff_root/.cache/toolchain/bin/bend"
fi
stiff_bend=${BEND:-$stiff_default}
stiff_cc=${CC:-clang}
if [ "$("$stiff_bend" version)" != 'bend 2.0.20' ]; then
  echo 'Stiff native effects require Bend 2.0.20.' >&2
  exit 1
fi
case "$2" in *.bend|*.c|*.js|*.mjs|*.json|*.md)
  echo 'Choose an executable output path, not a source/document path.' >&2
  exit 2 ;;
esac
mkdir -p "$(dirname "$2")"
BEND_NO_TELEMETRY=1 "$stiff_bend" "$1" -o "$2.c"
# Opt-in diagnostic ABI: retain the compiler pin and all sanitizer checks, but
# use ordinary C calls throughout the generated translation unit.
case "${STIFF_NATIVE_ABI:-compiler}" in
  compiler) ;;
  standard)
    [ "$(grep -cFx '#define PRESERVE(A) __attribute__((A))' "$2.c")" = 1 ] || {
      echo 'Unexpected Bend calling-convention definition; refusing to rewrite.' >&2; exit 1;
    }
    sed 's/^#define PRESERVE(A) __attribute__((A))$/#define PRESERVE(A)/' "$2.c" > "$2.c.abi"
    mv "$2.c.abi" "$2.c"
    ;;
  *) echo 'STIFF_NATIVE_ABI must be compiler or standard.' >&2; exit 2 ;;
esac
# pkg-config emits compiler argument words; this build assumes paths without spaces.
stiff_libraries='libcurl json-c'
if grep -q '^#define STIFF_SERVER_EFFECT 1' "$2.c"; then
  pkg-config --atleast-version=2.1.12 libevent || { echo 'Server builds require libevent 2.1.12 or newer.' >&2; exit 1; }
  stiff_libraries="$stiff_libraries libevent"
fi
stiff_flags=$(pkg-config --cflags --libs $stiff_libraries)
stiff_compile_flags=-O2
case "${STIFF_NATIVE_SANITIZE:-0}" in
  0) ;;
  1|combined) stiff_sanitizers=address,undefined ;;
  address|undefined) stiff_sanitizers=$STIFF_NATIVE_SANITIZE ;;
  *) echo 'STIFF_NATIVE_SANITIZE must be 0, address, undefined or combined.' >&2; exit 2 ;;
esac
if [ "${STIFF_NATIVE_SANITIZE:-0}" != 0 ]; then
  stiff_compile_flags="-O1 -g -fsanitize=$stiff_sanitizers -fno-sanitize-recover=all -fno-omit-frame-pointer"
fi
set -f
# Intentional word splitting of pkg-config flags, never evaluated as shell code.
"$stiff_cc" -std=c11 $stiff_compile_flags "$2.c" -lpthread -lm $stiff_flags -o "$2"
echo "Built $2. Native libraries: $stiff_libraries."
