.PHONY: build test app install run clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install:
	scripts/install.sh

run: app
	open build/btop-gui.app

clean:
	rm -rf .build build
