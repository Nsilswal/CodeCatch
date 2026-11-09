# Contributing to CodeCatch

Thanks for your interest in CodeCatch. This guide explains how to build the app, test it, and send a change.

## Ground rules

CodeCatch reads private messages, so a few rules never change:

- **No network access.** The app must never open a network connection.
- **Read-only.** The app opens the Messages database read-only. It never writes to it.
- **Nothing on disk.** Codes stay in memory. Do not log, cache, or save message text or codes.
- **No dependencies.** The app uses only Swift, AppKit, SwiftUI, and system libraries. Ask in an issue before you add a package.

A pull request that breaks one of these rules will not be merged.

## Build and test

You need macOS 13 or later and Xcode or the Command Line Tools (Swift 5.9 or later).

```sh
make test      # run the unit tests
make app       # build build/CodeCatch.app
make run       # build and open the app
make install   # build, copy to /Applications, and open
```

Useful flags while you work:

```sh
CODECATCH_DEMO=1 .build/debug/CodeCatch                    # show the copied popup at launch
build/CodeCatch.app/Contents/MacOS/CodeCatch --onboarding  # show the setup window
```

To test with real messages, the app needs Full Disk Access. Grant it to `build/CodeCatch.app` or `/Applications/CodeCatch.app`. Each rebuild has a new ad-hoc signature, so macOS can ask you to grant access again.

## Where things live

- `Sources/CodeCatchCore/`: the logic. All of it is unit tested.
  - `CodeExtractor.swift` finds the code in message text.
  - `AttributedBodyDecoder.swift` gets text out of the `attributedBody` blob.
  - `MessageStore.swift` reads `chat.db`.
  - `MessageWatcher.swift` watches for new messages.
- `Sources/CodeCatch/`: the menu bar app, the onboarding window, and the copied popup.
- `Tests/CodeCatchCoreTests/`: the unit tests.
- `Resources/AppIcon.svg`: the icon source. Run `swift scripts/make-icon.swift` after you edit it.

## A code was not detected

This is the most common kind of fix. Please follow these steps:

1. Add the message text as a test case in `Tests/CodeCatchCoreTests/CodeExtractorTests.swift`. **Replace the real code with different digits**, and remove names, phone numbers, and links.
2. Change `CodeExtractor.swift` so the new test passes.
3. Make sure all the old tests still pass. Also add a test for a similar message that must **not** match, if there is a risk of false positives.

If you do not want to write code, open an issue with the masked message text instead.

## Sending a pull request

1. Fork the repo and create a branch from `main`.
2. Keep each pull request to one change.
3. Run `make test` and `make app`. Both must succeed. CI runs the same checks.
4. If you change the UI, add a screenshot to the pull request. Check light and dark mode.
5. Describe what you changed and why.

## Style

- Follow the style of the code around your change.
- Prefer small, clear functions over clever code.
- Write comments that explain *why*, not *what*.
- Use short, plain sentences in user-facing text and docs.

## Reporting a security problem

Do not open a public issue for a security problem. Contact the maintainer privately, using the contact details on their [GitHub profile](https://github.com/Nsilswal).

## Code of conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By taking part, you agree to follow it.
