.PHONY: app install test run clean

app:
	./scripts/build-app.sh

install:
	./scripts/build-app.sh --install

test:
	swift test

run: app
	open build/CodeCatch.app

clean:
	rm -rf .build build
