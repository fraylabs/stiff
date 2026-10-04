.PHONY: check build run test mistakes verdict kernel test-sanitize

check:
	python3 tasks.py check

build:
	python3 tasks.py build

# From the example directory; a fresh DB starts at version 1 with 100 cents each.
run: build
	mkdir -p ../../.cache/ledger/state
	../../.cache/ledger/ledger --threads 2 ../../.cache/ledger/state/ledger.db 8080

test: build
	python3 tasks.py heavy python3 examples/ledger/test_ledger.py

mistakes:
	python3 tasks.py mistakes

verdict:
	python3 tasks.py verdict

# Optional independent kernel, scoped to this worktree (macOS arm64).
kernel:
	python3 setup-kernel.py

# Diagnostic compiler ABI profile; dependency libraries are not instrumented.
test-sanitize:
	STIFF_NATIVE_ABI=compiler STIFF_NATIVE_SANITIZE=combined LEDGER_BINARY=$(abspath ../../.cache/ledger/ledger-sanitized) python3 tasks.py build
	LEDGER_BINARY=$(abspath ../../.cache/ledger/ledger-sanitized) python3 tasks.py heavy python3 examples/ledger/test_ledger.py
