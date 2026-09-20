.PHONY: setup build check-dependency

setup: deps/stiff/.git
	python3 deps/stiff/scripts/setup.py

deps/stiff/.git:
	./fetch-stiff.sh

check-dependency: deps/stiff/.git
	@test "$$(git -C deps/stiff rev-parse HEAD)" = "$$(cat stiff.rev)" || { echo 'Dependency revision differs from stiff.rev.' >&2; exit 1; }
	@git -C deps/stiff diff --quiet HEAD -- || { echo 'Dependency has tracked edits.' >&2; exit 1; }

build: check-dependency
	./deps/stiff/scripts/build-native.sh main.bend build/auth-client
