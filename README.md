# Framewright (code name VidEdit)

<img src="docs/logo/framewright-icon.png" width="128" alt="Framewright icon">

A simple Premiere-style video editor for macOS. The product is called Framewright; targets, bundle identifiers and
source use the code name VidEdit.

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
#    Options (environment): BUILD_TOOLS=1 (default) also builds the static ffmpeg/ffprobe tools the
#    tests use to write MKV/WebM/Opus/AV1... test media (BUILD_TOOLS=0 skips them; those tests
#    then report XCTSkip); ENABLE_SVTAV1=1 (default) links the SVT-AV1 encoder into libavcodec
#    (ENABLE_SVTAV1=0 builds without AV1 encoding; AV1 decoding through dav1d is unaffected).

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

The build treats warnings as errors (`-Wall -Wextra` for C/Objective-C/C++,
`SWIFT_TREAT_WARNINGS_AS_ERRORS` for Swift).

## Signing

- **Debug** (what `build`/`test` above use) and **Release** are signed ad hoc
  (`CODE_SIGN_IDENTITY=-`) without the hardened runtime, so they build, test and launch
  headless with no developer account.
- **Distribution** (used by Archive) is Release plus the hardened runtime and a real identity,
  as notarized distribution outside the App Store requires. It defaults to
  `Developer ID Application`; set your team (and, if you like, another identity) in
  `Config/Signing.local.xcconfig` (gitignored; read by `Config/Distribution.xcconfig`):

  ```
  VIDEDIT_CODE_SIGN_IDENTITY = Developer ID Application
  VIDEDIT_DEVELOPMENT_TEAM = ABCDE12345
  ```

  or pass them on the command line:

  ```sh
  xcodebuild -scheme VidEdit -configuration Distribution -destination 'platform=macOS' \
      VIDEDIT_DEVELOPMENT_TEAM=ABCDE12345 build
  xcodebuild -scheme VidEdit -archivePath build/VidEdit.xcarchive \
      VIDEDIT_DEVELOPMENT_TEAM=ABCDE12345 archive
  ```

  The hardened runtime enables library validation, which loads only embedded code signed with
  the app's Team ID: the build re-signs VidEditEngine.framework and the FFmpeg dylibs with the
  app's identity when it copies them into `Contents/Frameworks` (CodeSignOnCopy), so they load,
  and the archive can be exported with Developer ID from the Organizer (which adds the secure
  timestamp) and notarized. An ad hoc build with the hardened runtime would abort at launch
  (dyld: "different Team IDs"), which is why Debug and Release keep it off.

The app runs with the App Sandbox enabled in every configuration.

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
- `Scripts/`: `build-ffmpeg.sh` (FFmpeg, see above), `make_test_media.swift` (writes the
  burn-in test media; EngineTests run it themselves and cache the output), `format.sh`.
- `Config/`: `Distribution.xcconfig` (identity and team of the Distribution configuration, see
  Signing).

## Formatting

```sh
brew install clang-format swiftformat   # optional
Scripts/format.sh           # format in place
Scripts/format.sh --check   # lint only
```

## FFmpeg and licensing

FFmpeg 7.1.5 is licensed under the GNU LGPL 2.1 or later. VidEdit builds it with
`--disable-gpl --disable-nonfree` (the build script fails if `config.h` says otherwise) and
ships it as separate, unmodified dylibs in `VidEdit.app/Contents/Frameworks`, loaded through
`@rpath`, so users can replace them with their own build as the LGPL requires (re-sign the
bundle afterwards). dav1d (BSD-2-Clause) and SVT-AV1 (BSD-3-Clause-Clear plus the AOMedia
patent licence) are linked statically into libavcodec.

- The complete licence texts and notices ship in the app (`Contents/Resources/Acknowledgements.md`
  and `COPYING.LGPLv2.1`) and are shown by **VidEdit > Acknowledgements…**; their sources are
  `App/Resources/`.
- Source offer: the FFmpeg libraries are built from the unmodified release tarball
  https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz (SHA-256 in `ThirdParty/VERSIONS.md`) by
  `Scripts/build-ffmpeg.sh`, which pins every version and checksum and records the exact
  configure flags; running it reproduces the shipped libraries. The author provides the
  complete corresponding source (tarballs and build script) of the FFmpeg libraries shipped with
  any VidEdit release on request, for at least three years after that release.
- nlohmann/json and doctest are MIT-licensed (doctest is used only to build the tests).
