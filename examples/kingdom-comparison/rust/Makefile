RUSTC ?= rustc
CACHE_DIR := ../../../.cache/kingdom-comparison/rust
BIN := $(CACHE_DIR)/kingdom
ENGINE_TEST_BIN := $(CACHE_DIR)/engine-tests
CLI_TEST_BIN := $(CACHE_DIR)/cli-tests

.PHONY: all build run test clean

all: build

build: $(BIN)

$(CACHE_DIR):
	mkdir -p "$@"

$(BIN): src/main.rs src/engine.rs | $(CACHE_DIR)
	$(RUSTC) --edition=2021 -D warnings -C opt-level=2 src/main.rs -o "$@"

$(ENGINE_TEST_BIN): src/engine.rs | $(CACHE_DIR)
	$(RUSTC) --edition=2021 -D warnings --test src/engine.rs -o "$@"

$(CLI_TEST_BIN): tests/cli.rs | $(CACHE_DIR)
	$(RUSTC) --edition=2021 -D warnings --test tests/cli.rs -o "$@"

run: build
	"$(BIN)" $(ARGS)

test: build $(ENGINE_TEST_BIN) $(CLI_TEST_BIN)
	"$(ENGINE_TEST_BIN)"
	KINGDOM_BIN="$(abspath $(BIN))" "$(CLI_TEST_BIN)"

clean:
	rm -rf "$(CACHE_DIR)"
