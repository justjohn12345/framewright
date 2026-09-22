# VidEdit

A native macOS non-linear video editor: an Objective-C++ engine framework
(`VidEditEngine`) with a Swift/SwiftUI app on top. See [PLAN.md](PLAN.md) for the
design and roadmap.

Requirements: macOS 14+ on Apple silicon, Xcode 26 (with its Metal Toolchain
component), Homebrew.

## Build

```sh
# 1. Tools (once)
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once per Xcode install; needed to compile .metal files

# 2. FFmpeg 7.1.5, LGPL-only, arm64 dylibs into ThirdParty/ffmpeg/ (a few minutes; skipped if already built)
Scripts/build-ffmpeg.sh            # add --force to rebuild from scratch

# 3. Generate VidEdit.xcodeproj from project.yml (FFmpeg must be built first)
xcodegen generate

# 4. Build the app
xcodebuild -scheme VidEdit -configuration Debug -destination 'platform=macOS' build

# 5. Run all tests (EngineTests + AppTests)
xcodebuild -scheme VidEdit -destination 'platform=macOS' test

# Engine tests only
xcodebuild -scheme EngineTests -destination 'platform=macOS' test
```

Re-run `xcodegen generate` after adding, removing or renaming files, and after
rebuilding FFmpeg. The `.xcodeproj` is generated and not checked in; `project.yml`
is the source of truth.

Signing is ad hoc (`CODE_SIGN_IDENTITY=-`), so everything builds headless with no
developer account. The app runs with the App Sandbox enabled.

## Open in Xcode

```sh
xcodegen generate && open VidEdit.xcodeproj
```

Pick the **VidEdit** scheme and press Run (Cmd+R) or Test (Cmd+U).

## Layout

- `Engine/`: `VidEditEngine.framework`, Objective-C++ (C++20, ARC). Public API lives
  in `Engine/Facade/` (umbrella header `VidEditEngine.h`); everything else is
  project-private. Metal shaders compile into the framework's `default.metallib`.
- `EngineTests/`: XCTest bundle (Objective-C++). Plain C++ tests use doctest
  `TEST_CASE`s in any `.cpp`/`.mm` file in this folder; they all run inside the
  `DoctestRunnerTests` XCTest.
- `App/`: the SwiftUI app. `AppTests/`: Swift tests hosted in the app.
- `ThirdParty/`: vendored `json.hpp` and `doctest.h` (see `ThirdParty/VERSIONS.md`)
  and the FFmpeg build output (`ffmpeg/`, not checked in).
- `Scripts/`: `build-ffmpeg.sh`, `format.sh`.

## Formatting

```sh
brew install clang-format swiftformat   # optional
Scripts/format.sh           # format in place
Scripts/format.sh --check   # lint only
```

## FFmpeg and licensing

FFmpeg is built with `--disable-gpl --disable-nonfree` (LGPL 2.1+) and shipped as
separate dylibs in `VidEdit.app/Contents/Frameworks`, loaded through `@rpath`, so
they can be replaced by the user as the LGPL requires.
