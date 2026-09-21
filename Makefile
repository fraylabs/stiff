.PHONY: setup build server test test-sanitize diagnose-sanitizers benchmark

setup:
	python3 scripts/setup.py

build:
	./scripts/build-native.sh examples/get-json.bend .cache/native/get-json

test:
	python3 -m unittest discover -s test -p 'test_*.py' -v

server:
	./scripts/build-native.sh examples/server.bend .cache/native/server

# Instrument all generated Bend and Stiff C using standard C calling conventions.
test-sanitize:
	STIFF_NATIVE_ABI=standard STIFF_NATIVE_SANITIZE=combined $(MAKE) test

diagnose-sanitizers:
	python3 scripts/diagnose-sanitizers.py

# Local loopback only. Raw reports and binaries stay ignored.
benchmark:
	python3 scripts/benchmark.py
