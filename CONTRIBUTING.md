# Contributing

Thanks for contributing to FastBar.

## Development

1. Fork the repository.
2. Create a branch from `main`.
3. Open `FastBar/FastBar.xcodeproj` in Xcode.
4. Keep changes focused and include a clear explanation in the pull request.

## Validation

Before opening a pull request, run:

```bash
xcodebuild -project FastBar/FastBar.xcodeproj \
  -scheme FastBar \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Also run `git diff --check` and test the menu-bar behavior on a Mac.

## Pull requests

Include:

1. What changed
2. Why it changed
3. How it was validated

Please follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
