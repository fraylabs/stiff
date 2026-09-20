#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
  echo 'Usage: scripts/build-native.sh program.bend output' >&2
  exit 2
fi
stiff_bend=${BEND:-bend}
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
# pkg-config emits compiler argument words; this build assumes paths without spaces.
stiff_flags=$(pkg-config --cflags --libs libcurl json-c)
set -f
# Intentional word splitting of pkg-config flags, never evaluated as shell code.
"$stiff_cc" -std=c11 -O2 "$2.c" -lpthread -lm $stiff_flags -o "$2"
echo "Built $2 without Node. Runtime requires libcurl and json-c."
