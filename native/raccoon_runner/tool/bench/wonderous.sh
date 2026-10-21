#!/usr/bin/env bash
# Prepares Flutter Wonderous for first_frame.py: clones it, adds the one-line
# first-frame probe to main(), and adds the host's desktop platform folder if
# the project lacks it. Prints the project path.
#
#   tool/bench/wonderous.sh [dir]        # default: $TMPDIR/raccoon-bench/wonderous
set -euo pipefail

DIR="${1:-${TMPDIR:-/tmp}/raccoon-bench/wonderous}"
if [ ! -d "$DIR/.git" ]; then
  mkdir -p "$(dirname "$DIR")"
  git clone -q --depth 1 https://github.com/gskinnerTeam/flutter-wonderous-app.git "$DIR"
fi
cd "$DIR"
if ! grep -q RACCOON_FIRST_FRAME lib/main.dart; then
  python3 - <<'PY'
p = 'lib/main.dart'
s = open(p).read()
anchor = '  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();\n'
assert anchor in s, 'Wonderous main() changed; add the probe by hand'
s = s.replace(anchor, anchor + "  widgetsBinding.waitUntilFirstFrameRasterized.then((_) => debugPrint('RACCOON_FIRST_FRAME'));\n", 1)
open(p, 'w').write(s)
PY
fi
case "$(uname -s)" in
  Darwin) platform=macos ;;
  MINGW*|MSYS*|CYGWIN*) platform=windows ;;
  *) platform=linux ;;
esac
if [ ! -d "$platform" ]; then
  flutter create --platforms="$platform" --project-name wonders . >/dev/null
fi
flutter pub get >/dev/null
echo "$DIR"
