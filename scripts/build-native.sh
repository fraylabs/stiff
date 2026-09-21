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
# Clang ASan does not preserve its own state across preserve_none calls. Keep
# Bend's preserve_most helpers, but use the standard convention at the two
# preserve_none work-loop sites when address instrumentation is active.
case "${STIFF_NATIVE_ABI:-compiler}" in
  compiler)
    case "${STIFF_NATIVE_SANITIZE:-0}" in
      1|address|combined)
        [ "$(grep -oF 'PRESERVE(preserve_none)' "$2.c" | wc -l | tr -d ' ')" = 2 ] || {
          echo 'Unexpected Bend preserve_none layout; refusing to rewrite.' >&2; exit 1;
        }
        sed 's/PRESERVE(preserve_none)//g' "$2.c" > "$2.c.abi"
        mv "$2.c.abi" "$2.c"
        ;;
    esac
    ;;
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
stiff_library_label=$stiff_libraries
stiff_libevent_flags=
if grep -q '^#define STIFF_SERVER_EFFECT 1' "$2.c"; then
  stiff_libevent="$stiff_root/.cache/libevent"
  stiff_libevent_pc="$stiff_libevent/lib/pkgconfig"
  [ -f "$stiff_libevent/.stiff-pin.json" ] &&
    [ -f "$stiff_libevent/lib/libevent_core.a" ] &&
    [ -f "$stiff_libevent/lib/libevent_extra.a" ] &&
    [ -f "$stiff_libevent/include/event2/http.h" ] || {
      echo 'Server builds require the pinned static libevent; run make setup.' >&2; exit 1;
    }
  grep -qF '  "archive_sha256": "4ab1b369bcb5af0c5971b8ade4e95a2c1326f6d0dc1ba75d620bf0331c3184a8",' \
    "$stiff_libevent/.stiff-pin.json" &&
    grep -qF '  "source_commit": "df3ecad3a040fd6d4fad4287defe113395de6fd7",' \
      "$stiff_libevent/.stiff-pin.json" &&
    grep -qF '      "path": "patches/libevent-error-headers.patch",' \
      "$stiff_libevent/.stiff-pin.json" &&
    grep -qF '      "sha256": "77f3200db9822c892f2eafe7ded46822add96c34fd0f4b3077f0d7d5addb6461",' \
      "$stiff_libevent/.stiff-pin.json" || {
        echo 'Scoped libevent source manifest does not match the pinned release.' >&2; exit 1;
      }
  PKG_CONFIG_PATH="$stiff_libevent_pc" PKG_CONFIG_LIBDIR="$stiff_libevent_pc" \
    pkg-config --exact-version=2.2.2 libevent_extra || {
      echo 'Scoped libevent pkg-config metadata does not match 2.2.2-alpha.' >&2; exit 1;
    }
  grep -qFx '#define EVENT__VERSION "2.2.2-alpha-dev"' \
    "$stiff_libevent/include/event2/event-config.h" || {
      echo 'Scoped libevent runtime headers do not match 2.2.2-alpha.' >&2; exit 1;
    }
  for stiff_symbol in evhttp_set_newreqcb evhttp_set_errorcb evhttp_request_set_chunked_cb; do
    grep -q "$stiff_symbol" "$stiff_libevent/include/event2/http.h" || {
      echo "Scoped libevent is missing $stiff_symbol." >&2; exit 1;
    }
  done
  stiff_libevent_flags=$(PKG_CONFIG_PATH="$stiff_libevent_pc" PKG_CONFIG_LIBDIR="$stiff_libevent_pc" \
    pkg-config --cflags --libs --static libevent_extra)
  stiff_library_label="$stiff_library_label pinned-libevent-2.2.2-alpha-static"
fi
if grep -q '^#define STIFF_STORE_EFFECT 1' "$2.c"; then
  pkg-config --exists sqlite3 || { echo 'Store builds require SQLite development files.' >&2; exit 1; }
  stiff_libraries="$stiff_libraries sqlite3"
fi
stiff_flags=$(pkg-config --cflags --libs $stiff_libraries)
# The scoped include must precede any transitive system include directory that
# also contains event2 headers.
stiff_flags="$stiff_libevent_flags $stiff_flags"
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
# Bend can generate deeply nested C for otherwise ordinary match chains.
# Set an explicit finite parser limit across Apple/upstream Clang defaults.
set -f
# Intentional word splitting of pkg-config flags, never evaluated as shell code.
"$stiff_cc" -std=c11 -fbracket-depth=1024 $stiff_compile_flags "$2.c" -lpthread -lm $stiff_flags -o "$2"
echo "Built $2. Native libraries: $stiff_library_label."
