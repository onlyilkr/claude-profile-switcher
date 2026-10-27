.PHONY: build test check app install dist preview clean

build:
	swift build

test:
	swift test

# What CI runs: tests, a release build of the app, and a smoke test of its command line.
check: test app
	"build/Claude Profile Switcher.app/Contents/MacOS/ClaudeProfileSwitcher" --help > /dev/null
	"build/Claude Profile Switcher.app/Contents/MacOS/ClaudeProfileSwitcher" --version

app:
	scripts/build-app.sh

install:
	scripts/build-app.sh install

# Release artifacts for a version, without publishing: make dist VERSION=1.2.3
dist:
	scripts/package-release.sh $(VERSION)

# Screenshots of the panel for the README, from sample accounts.
preview: build
	$$(swift build --show-bin-path)/ClaudeProfileSwitcher --render-panel-preview build/preview --lang en
	cp build/preview/accounts-light.png docs/images/panel-light.png
	cp build/preview/accounts-dark.png docs/images/panel-dark.png

clean:
	rm -rf .build build dist
