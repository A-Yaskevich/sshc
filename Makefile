BATS_BIN := tests/bats/bin/bats
SHELLCHECK := shellcheck

.PHONY: test test-unit test-integration test-deps lint

test-deps:
	git submodule update --init --recursive

test: test-deps
	$(BATS_BIN) tests/unit tests/integration

test-unit: test-deps
	$(BATS_BIN) tests/unit

test-integration: test-deps
	$(BATS_BIN) tests/integration

lint:
	$(SHELLCHECK) -S error -x sshc.sh tests/test_helper.bash tests/fixtures/bin/*
