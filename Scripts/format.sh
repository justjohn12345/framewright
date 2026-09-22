#!/usr/bin/env bash
# Formats the repo's own sources in place (never ThirdParty/).
#   Scripts/format.sh          # format
#   Scripts/format.sh --check  # report files that would change, exit 1 if any
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

status=0

if command -v clang-format >/dev/null 2>&1; then
    files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < <(
        find Engine EngineTests \( -name '*.h' -o -name '*.hpp' -o -name '*.mm' -o -name '*.m' \
            -o -name '*.cpp' -o -name '*.metal' \) -print0)
    if [[ ${#files[@]} -gt 0 ]]; then
        if [[ $CHECK -eq 1 ]]; then
            clang-format --dry-run --Werror "${files[@]}" || status=1
        else
            clang-format -i "${files[@]}"
        fi
    fi
else
    echo "clang-format not installed; skipping Objective-C++ (install: brew install clang-format)"
fi

if command -v swiftformat >/dev/null 2>&1; then
    if [[ $CHECK -eq 1 ]]; then
        swiftformat App AppTests --lint || status=1
    else
        swiftformat App AppTests
    fi
else
    echo "swiftformat not installed; skipping Swift (install: brew install swiftformat)"
fi

exit $status
