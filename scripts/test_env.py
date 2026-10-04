"""Keep native test PATH empty while allowing macOS sanitizer symbolization."""
from pathlib import Path
import sys


def sanitizer_env():
    # Apple Clang 21.0.0 (clang-2100.3.34.2) resolves atos at startup even
    # without a fault. Give it an absolute path, preserving every check and
    # diagnostic while leaving application executable lookup disabled.
    if sys.platform == "darwin" and Path("/usr/bin/atos").is_file():
        return {"ASAN_OPTIONS": "external_symbolizer_path=/usr/bin/atos",
                "UBSAN_OPTIONS": "external_symbolizer_path=/usr/bin/atos"}
    return {}
