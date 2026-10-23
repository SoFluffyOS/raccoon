#!/usr/bin/env bash
# Builds a throwaway macOS app on raccoon_view, plugins through CocoaPods
# (pods) or Swift Package Manager (spm), so a podspec or Package.swift that
# does not link is caught before an app finds it.
#
#   tool/build_macos_host.sh pods|spm
set -euo pipefail

mode="${1:-}"
case "$mode" in
  pods) spm=false ;;
  spm) spm=true ;;
  *) echo "usage: $0 pods|spm" >&2; exit 2 ;;
esac

view="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

flutter create --platforms=macos --project-name raccoon_host "$work/host" > /dev/null
cat >> "$work/host/pubspec.yaml" <<YAML
  config:
    enable-swift-package-manager: $spm
YAML
(cd "$work/host" && flutter pub add raccoon_view --path "$view" > /dev/null)
(cd "$work/host" && flutter build macos --debug)
