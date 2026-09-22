#!/usr/bin/env bash
# Builds an LGPL-only, arm64, shared-library FFmpeg into ThirdParty/ffmpeg/.
#
#   Scripts/build-ffmpeg.sh            # build if not already built
#   Scripts/build-ffmpeg.sh --force    # rebuild from a clean source tree
#
# Output: ThirdParty/ffmpeg/{include,lib}. Every dylib's install name is
# @rpath/<name>.dylib and all inter-library references go through @rpath, so
# the libraries work both from DerivedData and from VidEdit.app/Contents/Frameworks.
set -euo pipefail

# ---- Pinned release -----------------------------------------------------------
FFMPEG_VERSION="7.1.5"
FFMPEG_SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

# ---- Optional components ------------------------------------------------------
# ENABLE_SVTAV1: set to 1 (phase 7) to build SVT-AV1 (BSD-3) and link it via
# --enable-libsvtav1 for AV1 software encode. Not implemented yet; the script
# refuses to run with it on rather than silently producing a build without it.
ENABLE_SVTAV1="${ENABLE_SVTAV1:-0}"

# ---- Paths --------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="${ROOT}/ThirdParty/ffmpeg-src"
SRC_DIR="${SRC_ROOT}/ffmpeg-${FFMPEG_VERSION}"
TARBALL="${SRC_ROOT}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
PREFIX="${ROOT}/ThirdParty/ffmpeg"
STAMP="${PREFIX}/.built-${FFMPEG_VERSION}"
LIBS=(avutil swresample swscale avcodec avformat)

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ "$ENABLE_SVTAV1" != "0" ]]; then
    echo "error: ENABLE_SVTAV1=1 is reserved for phase 7 and not implemented yet" >&2
    exit 1
fi

if [[ $FORCE -eq 0 && -f "$STAMP" ]]; then
    echo "FFmpeg ${FFMPEG_VERSION} already built in ${PREFIX} (use --force to rebuild)"
    exit 0
fi

JOBS="$(sysctl -n hw.ncpu)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
export MACOSX_DEPLOYMENT_TARGET=14.0
CC="$(xcrun --sdk macosx -f clang)"

# ---- Fetch --------------------------------------------------------------------
mkdir -p "$SRC_ROOT"
if [[ ! -f "$TARBALL" ]]; then
    echo "==> Downloading ${FFMPEG_URL}"
    curl -fL --retry 3 -o "${TARBALL}.part" "$FFMPEG_URL"
    mv "${TARBALL}.part" "$TARBALL"
fi
echo "==> Verifying SHA-256"
echo "${FFMPEG_SHA256}  ${TARBALL}" | shasum -a 256 -c -

if [[ $FORCE -eq 1 || ! -d "$SRC_DIR" ]]; then
    rm -rf "$SRC_DIR"
    echo "==> Extracting"
    tar -xf "$TARBALL" -C "$SRC_ROOT"
fi

# ---- Configure / build / install ---------------------------------------------
rm -rf "$PREFIX"
cd "$SRC_DIR"
make distclean >/dev/null 2>&1 || true

echo "==> Configuring"
./configure \
    --prefix="$PREFIX" \
    --cc="$CC" \
    --arch=arm64 \
    --target-os=darwin \
    --extra-cflags="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -arch arm64" \
    --extra-ldflags="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -arch arm64" \
    --install-name-dir='@rpath' \
    --disable-gpl \
    --disable-nonfree \
    --enable-shared \
    --disable-static \
    --enable-pic \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --disable-programs \
    --disable-doc \
    --disable-x86asm \
    --disable-avdevice \
    --disable-avfilter \
    --disable-postproc \
    --disable-autodetect \
    --enable-pthreads \
    --enable-zlib \
    --enable-bzlib \
    --disable-debug

echo "==> Building with -j${JOBS}"
make -j"$JOBS"
make install

# ---- Flatten symlinks and fix install names -----------------------------------
# FFmpeg installs libX.<major>.<minor>.<micro>.dylib plus two symlinks. Each
# library's install name (and therefore every reference to it) is the
# major-versioned name, so that is the only file the app needs. Make it the real
# file and keep libX.dylib as a symlink for the linker's -lX lookup. This lets
# Xcode copy plain files into Contents/Frameworks without symlink handling.
#
# configure's --install-name-dir already writes @rpath ids; the install_name_tool
# pass enforces it (and rewrites any absolute inter-library references) so the
# result does not depend on FFmpeg's build-system defaults.
echo "==> Flattening dylibs and rewriting install names to @rpath"
cd "$PREFIX/lib"
major_file() { # libavutil -> libavutil.59.dylib
    local f
    for f in "$1".*.dylib; do
        [[ "$f" =~ ^$1\.[0-9]+\.dylib$ ]] && { echo "$f"; return; }
    done
}
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
    # install_name_tool invalidates the linker's ad hoc signature; re-sign so the
    # dylibs load on Apple silicon. The app build re-signs them with its identity.
    codesign --force --sign - "$major"
done

# ---- Verify -------------------------------------------------------------------
echo "==> Verifying"
status=0
for lib in "${LIBS[@]}"; do
    file="$(major_file "lib${lib}")"
    lipo -archs "$file" | grep -qx arm64 || { echo "  $file is not arm64" >&2; status=1; }
    id="$(otool -D "$file" | tail -n1)"
    [[ "$id" == @rpath/* ]] || { echo "  $file id is $id" >&2; status=1; }
    if otool -L "$file" | tail -n +2 | awk '{print $1}' | grep -E '/lib(av|sw)' | grep -v '^@rpath/'; then
        echo "  $file has non-@rpath FFmpeg references" >&2; status=1
    fi
    echo "  $file:"; otool -L "$file" | tail -n +2 | sed 's/^/  /'
done
if grep -Eq '^#define CONFIG_(GPL|NONFREE) 1' "$SRC_DIR/config.h"; then
    echo "  GPL or nonfree code enabled" >&2; status=1
fi
[[ $status -eq 0 ]] || { echo "verification failed" >&2; exit 1; }

echo "FFmpeg ${FFMPEG_VERSION} (LGPL, arm64, ${#LIBS[@]} libraries) installed in ${PREFIX}"
touch "$STAMP"
