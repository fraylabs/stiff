.PHONY: setup build test

setup:
	python3 scripts/setup.py

build:
	./scripts/build-native.sh examples/get-json.bend .cache/native/get-json

test:
	python3 -m unittest discover -s test -p 'test_*.py' -v
