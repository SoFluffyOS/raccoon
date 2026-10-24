#!/usr/bin/env bash
# Builds a throwaway desktop app on raccoon_view, so the plugin's native half
# is compiled and linked as an app would: on macOS with plugins through
# CocoaPods (pods) or Swift Package Manager (spm), on Linux and Windows the
# one way there is.
#
#   tool/build_host.sh macos pods|spm
#   tool/build_host.sh linux
#   tool/build_host.sh windows
set -euo pipefail

platform="${1:-}"
case "$platform" in
  macos)
    case "${2:-}" in
      pods) spm=false ;;
      spm) spm=true ;;
      *) echo "usage: $0 macos pods|spm" >&2; exit 2 ;;
    esac
    ;;
  linux | windows) ;;
  *) echo "usage: $0 macos pods|spm | linux | windows" >&2; exit 2 ;;
esac

view="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Git Bash on Windows: Flutter takes Windows paths.
if command -v cygpath > /dev/null; then
  view="$(cygpath -w "$view")"
  work="$(cygpath -w "$work")"
fi

flutter create --platforms="$platform" --project-name raccoon_host "$work/host" > /dev/null
if [ "$platform" = macos ]; then
  cat >> "$work/host/pubspec.yaml" <<YAML
  config:
    enable-swift-package-manager: $spm
YAML
fi
(cd "$work/host" && flutter pub add raccoon_view --path "$view" > /dev/null)
(cd "$work/host" && flutter build "$platform" --debug)
