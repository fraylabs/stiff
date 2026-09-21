.PHONY: setup build server test test-sanitize diagnose-sanitizers benchmark

setup:
	python3 scripts/setup.py

build:
	./scripts/build-native.sh examples/get-json.bend .cache/native/get-json

test:
	python3 -m unittest discover -s test -p 'test_*.py' -v

server:
	./scripts/build-native.sh examples/server.bend .cache/native/server

# Instrument all generated Bend and Stiff C. The compiler profile retains
# preserve_most and removes only ASan-incompatible preserve_none sites.
test-sanitize:
	STIFF_NATIVE_ABI=compiler STIFF_NATIVE_SANITIZE=combined $(MAKE) test

diagnose-sanitizers:
	python3 scripts/diagnose-sanitizers.py

# Local loopback only. Raw reports and binaries stay ignored.
benchmark:
	python3 scripts/benchmark.py

# Native process supervisor; no interpreter is needed at deployment.
.PHONY: runner
runner:
	mkdir -p .cache/native
	$(CC) -std=c11 -Wall -Wextra -Werror -O2 native/stiff-run.c -o .cache/native/stiff-run
