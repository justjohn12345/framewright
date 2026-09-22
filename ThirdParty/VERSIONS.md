# Vendored third-party code

| Component | Version | File | Source | SHA-256 | License |
|---|---|---|---|---|---|
| nlohmann/json | 3.12.0 | `json.hpp` | https://github.com/nlohmann/json/releases/download/v3.12.0/json.hpp | `aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63` | MIT |
| doctest | 2.4.12 (tag commit `1da23a3e8119ec5cce4f9388e91b065e20bf06f5`) | `doctest.h` | https://raw.githubusercontent.com/doctest/doctest/v2.4.12/doctest/doctest.h | `94029a7d32da24a56249658147dbd2b33ff0b9ed665295cbbaf19aafff5b0ced` | MIT |
| FFmpeg | 7.1.5 | built into `ffmpeg/` (not committed) by `Scripts/build-ffmpeg.sh` | https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz | `de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f` (tarball) | LGPL 2.1+ (built with `--disable-gpl --disable-nonfree`) |

doctest is pinned to the 2.4.x line on purpose (2.5.x exists upstream).

To verify the vendored headers:

```sh
shasum -a 256 ThirdParty/json.hpp ThirdParty/doctest.h
```

To update: download the new file from the source URL, replace it, update the version and hash here,
and run the EngineTests (which compile and exercise both headers).
