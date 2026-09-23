#!/usr/bin/env bash
# Builds an LGPL-only, arm64 FFmpeg for the engine, plus a static FFmpeg command-line tool set
# used to synthesise test media.
#
#   Scripts/build-ffmpeg.sh            # build if the recorded build does not match this script
#   Scripts/build-ffmpeg.sh --force    # rebuild everything from freshly extracted sources
#
# Outputs
#   ThirdParty/ffmpeg/{include,lib}        shared libraries the engine links and the app embeds.
#       Every dylib's install name is @rpath/<name>.dylib and all inter-library references go
#       through @rpath, so they work from DerivedData and from Framewright.app/Contents/Frameworks.
#       dav1d (AV1 decode) and SVT-AV1 (AV1 encode) are linked statically INTO libavcodec, so the
#       set of dylibs to bundle does not change.
#   ThirdParty/ffmpeg/tools/bin/{ffmpeg,ffprobe}
#       statically linked command-line tools (same LGPL configuration plus libavfilter, which
#       the ffmpeg program requires). Never shipped: EngineTests use them to write media the
#       engine's own writers cannot (Matroska/WebM variants, Opus/Vorbis/FLAC, AV1, MPEG-TS
#       with offsets, rotated streams, MPEG-4 Part 2 ASP). Set BUILD_TOOLS=0 to skip them; the
#       tests that need them then report XCTSkip.
#
# Rebuild policy: the build is recorded in ThirdParty/ffmpeg/.build-stamp as the SHA-256 of
# this script (which contains every version, checksum and configure flag) and the options
# below. Any edit to the script, a different option, or a missing stamp rebuilds. Everything is
# built into a staging directory; the previous install stays in place until the new one has
# been built and verified, and is then replaced with two renames.
#
# Licensing: FFmpeg is configured with --disable-gpl --disable-nonfree and the check below
# fails the build if config.h says otherwise. dav1d is BSD-2-Clause; SVT-AV1 is BSD-3-Clause
# (Clear) plus the AOMedia patent licence; both are compatible with an LGPL FFmpeg.
#
# Checksum provenance (recorded 2026-09-22):
#   FFmpeg 7.1.5  sha256 from the tarball after `gpgv` verified ffmpeg-7.1.5.tar.xz.asc with
#                 the FFmpeg release key FCF986EA15E6E293A5644F10B4322F04D67658D8
#                 ("FFmpeg release signing key <ffmpeg-devel@ffmpeg.org>", https://ffmpeg.org/ffmpeg-devel.asc).
#   dav1d 1.5.4   sha256 equal to the published dav1d-1.5.4.tar.xz.sha256, and `gpgv` verified
#                 dav1d-1.5.4.tar.xz.asc with the VideoLAN release key
#                 65F7C6B4206BD057A7EB73787180713BE58D1ADC (signature made 2026-07-14, before the
#                 key's 2026-08-01 expiry).
#   SVT-AV1 3.1.2 GitLab tag archive; the project publishes no signatures or checksums, so the
#                 sha256 is trust-on-first-use from https://gitlab.com/AOMediaCodec/SVT-AV1 on
#                 2026-09-22.
#   meson/ninja/cmake/pkgconf wheels: sha256 digests published by PyPI, enforced by
#                 `pip --require-hashes`.
# When gpgv is installed the script re-verifies the FFmpeg and dav1d signatures on every
# download (the keys are fetched from their publishers and must have the pinned fingerprints);
# without gpgv the pinned SHA-256s above are the check.
set -euo pipefail
# Note: with pipefail, `producer | grep -q` can fail spuriously (grep exits at the first match and
# the producer dies of SIGPIPE), so pipelines below use `grep ... >/dev/null` instead.

# ---- Pinned releases ----------------------------------------------------------
FFMPEG_VERSION="7.1.5"
FFMPEG_SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_KEY_URL="https://ffmpeg.org/ffmpeg-devel.asc"
FFMPEG_KEY_FPR="FCF986EA15E6E293A5644F10B4322F04D67658D8"

DAV1D_VERSION="1.5.4"
DAV1D_SHA256="686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
DAV1D_URL="https://downloads.videolan.org/pub/videolan/dav1d/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.xz"
DAV1D_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x65F7C6B4206BD057A7EB73787180713BE58D1ADC"
DAV1D_KEY_FPR="65F7C6B4206BD057A7EB73787180713BE58D1ADC"

SVTAV1_VERSION="3.1.2"
SVTAV1_SHA256="d0d73bfea42fdcc1222272bf2b0e2319e9df5574721298090c3d28315586ecb1"
SVTAV1_URL="https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVTAV1_VERSION}/SVT-AV1-v${SVTAV1_VERSION}.tar.gz"

# Build tools, installed into a private virtualenv (nothing is installed system-wide).
BUILD_TOOL_REQUIREMENTS="
meson==1.12.1 --hash=sha256:930bc7542cbd9f57009e182fd014eba48cf1a0180a7b9006d2d32d8f168d8b02
ninja==1.13.2 --hash=sha256:fd82e26c0706ad4ab88e5fdd26f3fab0a987a90f810160f6c322e752c6af298b
cmake==4.4.3 --hash=sha256:6c95b37116bb5c714656e4f76931ebdcb739209a1aee91cf51408ccfe137694e
pkgconf==3.0.7.post0 --hash=sha256:47cbf6889d84297b9a4e1741ae016daa4e198f3ec8bab7ce74554cc50b77cce4
"

# ---- Options --------------------------------------------------------------------
# ENABLE_SVTAV1=0 builds without the SVT-AV1 encoder (AV1 export and the AV1 test clips then
# become unavailable; decode through dav1d is unaffected).
ENABLE_SVTAV1="${ENABLE_SVTAV1:-1}"
BUILD_TOOLS="${BUILD_TOOLS:-1}"

# ---- Paths --------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/Scripts/build-ffmpeg.sh"
SRC_ROOT="${ROOT}/ThirdParty/ffmpeg-src"
WORK="${SRC_ROOT}/work"                 # extracted sources and build trees, recreated per build
DEPS="${WORK}/deps"                     # static dav1d / SVT-AV1 install
VENV="${SRC_ROOT}/build-tools-venv"
PREFIX="${ROOT}/ThirdParty/ffmpeg"
STAMP="${PREFIX}/.build-stamp"
LIBS=(avutil swresample swscale avcodec avformat)

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# The stamp covers the script (every version, checksum and flag lives in it) and the options.
BUILD_ID="$( {
    shasum -a 256 "$SCRIPT" | cut -d' ' -f1
    echo "svtav1=${ENABLE_SVTAV1} tools=${BUILD_TOOLS}"
} | shasum -a 256 | cut -d' ' -f1)"

if [[ $FORCE -eq 0 && -f "$STAMP" && "$(cat "$STAMP")" == "$BUILD_ID" ]]; then
    echo "FFmpeg ${FFMPEG_VERSION} already built for this script revision (use --force to rebuild)"
    exit 0
fi

JOBS="$(sysctl -n hw.ncpu)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
export MACOSX_DEPLOYMENT_TARGET=14.0
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"
ARCH_FLAGS="-arch arm64 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"

# Scratch space for signatures and requirement files, and the staging directory for the install
# (on the same volume as the destination, so swapping it in is a rename). Both are removed on
# exit whatever happens.
SCRATCH="$(mktemp -d "${TMPDIR:-/private/var/tmp}/framewright-ffmpeg.XXXXXX")"
STAGE_ROOT="${SRC_ROOT}/stage.$$"
cleanup() { rm -rf "$SCRATCH" "$STAGE_ROOT"; }
trap cleanup EXIT

# ---- Fetch and verify -----------------------------------------------------------
mkdir -p "$SRC_ROOT"

fetch() { # url destination
    if [[ ! -f "$2" ]]; then
        echo "==> Downloading $1"
        curl -fL --retry 3 -o "$2.part" "$1"
        mv "$2.part" "$2"
    fi
}

verify_sha256() { # file sha256
    echo "$2  $1" | shasum -a 256 -c - >/dev/null || {
        echo "error: SHA-256 mismatch for $1 (delete it to re-download)" >&2
        exit 1
    }
}

# Verifies a detached signature with gpgv when available. The key is downloaded from its
# publisher and must carry the pinned fingerprint.
verify_signature() { # file signature-url key-url fingerprint
    if ! command -v gpgv >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
        echo "    gpgv not installed: relying on the pinned SHA-256 (see provenance in the header)"
        return 0
    fi
    local sig="$1.asc" key="${SCRATCH}/key.asc" ring="${SCRATCH}/key.gpg"
    fetch "$2" "$sig"
    curl -fsL --retry 3 -o "$key" "$3"
    # --show-keys parses without importing (no keyring, no agent).
    if ! gpg --batch --with-colons --show-keys "$key" 2>/dev/null | grep "^fpr:::::::::$4:" >/dev/null; then
        echo "error: the key from $3 does not have fingerprint $4" >&2
        exit 1
    fi
    gpg --batch --dearmor <"$key" >"$ring"
    if ! gpgv --keyring "$ring" "$sig" "$1" 2>"${SCRATCH}/gpgv.log"; then
        cat "${SCRATCH}/gpgv.log" >&2
        echo "error: bad signature on $1" >&2
        exit 1
    fi
    echo "    signature OK ($4)"
}

FFMPEG_TARBALL="${SRC_ROOT}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
DAV1D_TARBALL="${SRC_ROOT}/dav1d-${DAV1D_VERSION}.tar.xz"
SVTAV1_TARBALL="${SRC_ROOT}/SVT-AV1-v${SVTAV1_VERSION}.tar.gz"

fetch "$FFMPEG_URL" "$FFMPEG_TARBALL"
fetch "$DAV1D_URL" "$DAV1D_TARBALL"
[[ "$ENABLE_SVTAV1" != "0" ]] && fetch "$SVTAV1_URL" "$SVTAV1_TARBALL"

echo "==> Verifying downloads"
verify_sha256 "$FFMPEG_TARBALL" "$FFMPEG_SHA256"
verify_signature "$FFMPEG_TARBALL" "${FFMPEG_URL}.asc" "$FFMPEG_KEY_URL" "$FFMPEG_KEY_FPR"
verify_sha256 "$DAV1D_TARBALL" "$DAV1D_SHA256"
verify_signature "$DAV1D_TARBALL" "${DAV1D_URL}.asc" "$DAV1D_KEY_URL" "$DAV1D_KEY_FPR"
if [[ "$ENABLE_SVTAV1" != "0" ]]; then
    verify_sha256 "$SVTAV1_TARBALL" "$SVTAV1_SHA256"
fi

# ---- Build tools ------------------------------------------------------------------
REQUIREMENTS_ID="$(printf '%s' "$BUILD_TOOL_REQUIREMENTS" | shasum -a 256 | cut -d' ' -f1)"
if [[ ! -x "${VENV}/bin/meson" || ! -x "${VENV}/bin/ninja" || ! -x "${VENV}/bin/cmake" || ! -x "${VENV}/bin/pkgconf" ||
      ! -f "${VENV}/.requirements-id" || "$(cat "${VENV}/.requirements-id")" != "$REQUIREMENTS_ID" ]]; then
    echo "==> Installing pinned build tools into ${VENV}"
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    printf '%s\n' "$BUILD_TOOL_REQUIREMENTS" >"${SCRATCH}/requirements.txt"
    "${VENV}/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: \
        -r "${SCRATCH}/requirements.txt"
    printf '%s' "$REQUIREMENTS_ID" >"${VENV}/.requirements-id"
fi
MESON="${VENV}/bin/meson"
NINJA="${VENV}/bin/ninja"
CMAKE="${VENV}/bin/cmake"
PKGCONF="${VENV}/bin/pkgconf"
export PATH="${VENV}/bin:${PATH}"

# ---- Fresh sources ------------------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK" "$DEPS"
echo "==> Extracting sources"
tar -xf "$FFMPEG_TARBALL" -C "$WORK"
tar -xf "$DAV1D_TARBALL" -C "$WORK"
[[ "$ENABLE_SVTAV1" != "0" ]] && tar -xf "$SVTAV1_TARBALL" -C "$WORK"
FFMPEG_SRC="${WORK}/ffmpeg-${FFMPEG_VERSION}"

# ---- dav1d (static) ---------------------------------------------------------------
echo "==> Building dav1d ${DAV1D_VERSION}"
CC="$CC" CFLAGS="$ARCH_FLAGS" LDFLAGS="$ARCH_FLAGS" "$MESON" setup "${WORK}/dav1d-build" "${WORK}/dav1d-${DAV1D_VERSION}" \
    --prefix="$DEPS" --libdir=lib --buildtype=release --default-library=static -Db_ndebug=true \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false >/dev/null
"$NINJA" -C "${WORK}/dav1d-build" -j"$JOBS" install >/dev/null

# ---- SVT-AV1 (static) ---------------------------------------------------------------
if [[ "$ENABLE_SVTAV1" != "0" ]]; then
    echo "==> Building SVT-AV1 ${SVTAV1_VERSION}"
    "$CMAKE" -S "${WORK}/SVT-AV1-v${SVTAV1_VERSION}" -B "${WORK}/svtav1-build" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF \
        -DBUILD_TESTING=OFF >/dev/null
    "$CMAKE" --build "${WORK}/svtav1-build" -j"$JOBS" >/dev/null
    "$CMAKE" --install "${WORK}/svtav1-build" >/dev/null
fi

# ---- FFmpeg configuration shared by both builds -------------------------------------
# --disable-autodetect: nothing is picked up from the host (no Homebrew libraries, SDL, iconv,
# securetransport, etc.), so the build is reproducible; everything wanted is enabled
# explicitly below (VideoToolbox/AudioToolbox hardware paths, zlib/bzlib for Matroska and PNG).
COMMON_FLAGS=(
    --cc="$CC"
    --arch=arm64
    --target-os=darwin
    --extra-cflags="$ARCH_FLAGS -I${DEPS}/include"
    --extra-ldflags="$ARCH_FLAGS -L${DEPS}/lib"
    --pkg-config="$PKGCONF"
    --pkg-config-flags=--static
    --disable-gpl
    --disable-nonfree
    --enable-pic
    --enable-videotoolbox
    --enable-audiotoolbox
    --disable-doc
    --disable-x86asm
    --disable-avdevice
    --disable-postproc
    --disable-autodetect
    --enable-pthreads
    --enable-zlib
    --enable-bzlib
    --enable-libdav1d
    --disable-debug
)
if [[ "$ENABLE_SVTAV1" != "0" ]]; then
    COMMON_FLAGS+=(--enable-libsvtav1)
fi
export PKG_CONFIG_PATH="${DEPS}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS}/lib/pkgconfig"

check_license() { # build-dir
    if grep -Eq '^#define CONFIG_(GPL|NONFREE) 1' "$1/config.h"; then
        echo "error: GPL or nonfree code enabled in $1" >&2
        exit 1
    fi
    grep -q '^#define CONFIG_LIBDAV1D_DECODER 1' "$1/config_components.h" || {
        echo "error: libdav1d decoder missing in $1" >&2
        exit 1
    }
    if [[ "$ENABLE_SVTAV1" != "0" ]]; then
        grep -q '^#define CONFIG_LIBSVTAV1_ENCODER 1' "$1/config_components.h" || {
            echo "error: libsvtav1 encoder missing in $1" >&2
            exit 1
        }
    fi
}


# ---- Engine libraries (shared) ------------------------------------------------------
build_engine() {
    local build="${WORK}/build-shared"
    mkdir -p "$build"
    echo "==> Configuring FFmpeg ${FFMPEG_VERSION} (shared, engine)"
    (cd "$build" && "${FFMPEG_SRC}/configure" \
        --prefix="$PREFIX" \
        --install-name-dir='@rpath' \
        --enable-shared \
        --disable-static \
        --disable-programs \
        --disable-avfilter \
        "${COMMON_FLAGS[@]}" >"${build}/configure.log") || {
        tail -40 "${build}/ffbuild/config.log" >&2
        exit 1
    }
    check_license "$build"
    echo "==> Building FFmpeg (shared) with -j${JOBS}"
    make -C "$build" -j"$JOBS" >/dev/null
    make -C "$build" install DESTDIR="$STAGE_ROOT" >/dev/null
    local staged="${STAGE_ROOT}${PREFIX}"

    # Flatten symlinks and fix install names. FFmpeg installs libX.<major>.<minor>.<micro>.dylib
    # plus two symlinks. Each library's install name (and therefore every reference to it) is
    # the major-versioned name, so that is the only file the app needs: make it the real file
    # and keep libX.dylib as a symlink for the linker's -lX lookup, so Xcode copies plain files
    # into Contents/Frameworks. configure's --install-name-dir already writes @rpath ids; the
    # install_name_tool pass enforces it (and rewrites any absolute inter-library references).
    echo "==> Flattening dylibs and rewriting install names to @rpath"
    (
        cd "${staged}/lib"
        for lib in "${LIBS[@]}"; do
            major="$(major_file "lib${lib}")"
            [[ -n "$major" ]] || { echo "missing lib${lib}.<major>.dylib" >&2; exit 1; }
            if [[ -L "$major" ]]; then
                target="$(readlink "$major")"
                rm "$major"
                mv "$target" "$major"
            fi
            rm -f "lib${lib}".*.*.*.dylib
            ln -sf "$major" "lib${lib}.dylib"
            install_name_tool -id "@rpath/${major}" "$major" 2>/dev/null
            while read -r dep; do
                base="$(basename "$dep")"
                case "$base" in libav*|libsw*)
                    [[ "$dep" == "@rpath/${base}" ]] || install_name_tool -change "$dep" "@rpath/${base}" "$major" 2>/dev/null
                esac
            done < <(otool -L "$major" | tail -n +2 | awk '{print $1}')
            # install_name_tool invalidates the linker's ad hoc signature; re-sign so the dylibs
            # load on Apple silicon. The app build re-signs them with its identity.
            codesign --force --sign - "$major"
        done
    )

    echo "==> Verifying"
    local status=0
    for lib in "${LIBS[@]}"; do
        local file
        file="${staged}/lib/$(cd "${staged}/lib" && major_file "lib${lib}")"
        lipo -archs "$file" | grep -x arm64 >/dev/null || { echo "  $file is not arm64" >&2; status=1; }
        local id
        id="$(otool -D "$file" | tail -n1)"
        [[ "$id" == @rpath/* ]] || { echo "  $file id is $id" >&2; status=1; }
        if otool -L "$file" | tail -n +2 | awk '{print $1}' | grep -E '/lib(av|sw)' | grep -v '^@rpath/'; then
            echo "  $file has non-@rpath FFmpeg references" >&2; status=1
        fi
        # dav1d and SVT-AV1 must be inside libavcodec, not dynamic dependencies.
        if otool -L "$file" | tail -n +2 | awk '{print $1}' | grep -E 'dav1d|SvtAv1' >/dev/null; then
            echo "  $file links dav1d/SVT-AV1 dynamically" >&2; status=1
        fi
        echo "  $(basename "$file"):"; otool -L "$file" | tail -n +2 | sed 's/^/  /'
    done
    strings - "${staged}/lib/$(cd "${staged}/lib" && major_file libavcodec)" | grep -x 'libdav1d' >/dev/null || {
        echo "  libavcodec does not contain the libdav1d decoder" >&2; status=1
    }
    [[ $status -eq 0 ]] || { echo "verification failed; the previous install in ${PREFIX} is untouched" >&2; exit 1; }
}

major_file() { # libavutil -> libavutil.59.dylib
    local f
    for f in "$1".*.dylib; do
        [[ "$f" =~ ^$1\.[0-9]+\.dylib$ ]] && { echo "$f"; return; }
    done
}

# ---- Command-line tools (static, test media only) -----------------------------------
build_tools() {
    local build="${WORK}/build-tools"
    local stage="${WORK}/tools-install"
    mkdir -p "$build"
    echo "==> Configuring FFmpeg ${FFMPEG_VERSION} (static command-line tools)"
    (cd "$build" && "${FFMPEG_SRC}/configure" \
        --prefix=/tools \
        --enable-static \
        --disable-shared \
        --enable-ffmpeg \
        --enable-ffprobe \
        --disable-ffplay \
        --enable-avfilter \
        "${COMMON_FLAGS[@]}" >"${build}/configure.log") || {
        tail -40 "${build}/ffbuild/config.log" >&2
        exit 1
    }
    check_license "$build"
    echo "==> Building FFmpeg tools with -j${JOBS}"
    make -C "$build" -j"$JOBS" >/dev/null
    make -C "$build" install-progs DESTDIR="$stage" >/dev/null
    # Only the programs are installed: the static libraries and headers would just be confusing.
    local staged="${STAGE_ROOT}${PREFIX}/tools"
    mkdir -p "${staged}/bin"
    cp "${stage}/tools/bin/ffmpeg" "${stage}/tools/bin/ffprobe" "${staged}/bin/"
    local tool
    for tool in ffmpeg ffprobe; do
        lipo -archs "${staged}/bin/${tool}" | grep -x arm64 >/dev/null || { echo "${tool} is not arm64" >&2; exit 1; }
        if otool -L "${staged}/bin/${tool}" | tail -n +2 | awk '{print $1}' | grep -E 'lib(av|sw)|dav1d|SvtAv1' >/dev/null; then
            echo "${tool} is not statically linked" >&2; exit 1
        fi
        "${staged}/bin/${tool}" -hide_banner -version >/dev/null
    done
    "${staged}/bin/ffmpeg" -hide_banner -decoders 2>/dev/null | grep libdav1d >/dev/null || { echo "ffmpeg lacks libdav1d" >&2; exit 1; }
}

build_engine
if [[ "$BUILD_TOOLS" != "0" ]]; then
    build_tools
fi

# Swap the verified build in. The old install is only removed after the new one is in place.
staged="${STAGE_ROOT}${PREFIX}"
printf '%s' "$BUILD_ID" >"${staged}/.build-stamp"
old="${PREFIX}.old.$$"
if [[ -e "$PREFIX" ]]; then
    mv "$PREFIX" "$old"
fi
mv "$staged" "$PREFIX"
rm -rf "$old" "$WORK"
echo "FFmpeg ${FFMPEG_VERSION} (LGPL, arm64, ${#LIBS[@]} libraries, dav1d ${DAV1D_VERSION}$(
    [[ "$ENABLE_SVTAV1" != "0" ]] && echo ", SVT-AV1 ${SVTAV1_VERSION}")) installed in ${PREFIX}"
[[ "$BUILD_TOOLS" != "0" ]] && echo "Command-line tools (test media only) in ${PREFIX}/tools/bin"
exit 0
