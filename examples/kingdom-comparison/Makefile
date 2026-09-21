.PHONY: test bend rust mutations

# Run from this directory or with make -C examples/kingdom-comparison test.
test: bend rust
	python3 compare.py --bend ../../.cache/kingdom-comparison/bend/kingdom --rust ../../.cache/kingdom-comparison/rust/kingdom --output ../../.cache/kingdom-comparison/comparison.json

bend:
	cd ../.. && ./examples/kingdom-comparison/bend/test.sh

rust:
	$(MAKE) -C rust test

mutations: bend rust
	python3 mutations.py --output ../../.cache/kingdom-comparison/mutations.json
