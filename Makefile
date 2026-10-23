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
	open "build/No Beachballs.app"

clean:
	rm -rf .build build
