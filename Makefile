.PHONY: all check lint test build run screenshot hooks

SCRIPTS := game.sh slash sprites test.sh

all: check

hooks:
	@git config core.hooksPath .githooks
	@echo "Configured git core.hooksPath -> .githooks"

lint:
	bash -n $(SCRIPTS)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S error $(SCRIPTS); \
	fi

test:
	./test.sh

check: lint test

build:
	./slash -b

screenshot:
	./slash -s

run:
	./slash
