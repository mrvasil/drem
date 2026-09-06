.PHONY: check test build run install

check:
	python3 scripts/check-repository.py
	python3 -m unittest discover -s scripts/tests -v

test:
	swift run drem-selftest
	zsh scripts/test-automation.sh

build:
	./scripts/build-app.sh

run: build
	open "$(CURDIR)/dist/drem.app"

install: build
	mkdir -p "$(HOME)/Applications"
	ditto "$(CURDIR)/dist/drem.app" "$(HOME)/Applications/drem.app"
	./scripts/install-hooks.py
	open "$(HOME)/Applications/drem.app"
