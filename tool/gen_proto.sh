#!/usr/bin/env bash
# Regenerates lib/src/proto from the runner's proto files. Needs protoc (see
# native/raccoon_runner/tool/protoc.sh) and the Dart plugin, which is
# activated for the dart on the PATH when missing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="${RACCOON_PROTO_DIR:-$ROOT/../../native/raccoon_runner/proto}"
PROTOC="${PROTOC:-$HOME/.local/raccoon/protoc/bin/protoc}"

dart pub global list | grep -q '^protoc_plugin ' || dart pub global activate protoc_plugin
# protoc wants an executable; this one runs the plugin of the active dart,
# whichever pub cache it lives in.
PLUGIN="$(mktemp -d)/protoc-gen-dart"
printf '#!/bin/sh\nexec dart pub global run protoc_plugin "$@"\n' > "$PLUGIN"
chmod +x "$PLUGIN"

"$PROTOC" -I "$PROTO_DIR" --dart_out="$ROOT/lib/src/proto" \
  --plugin=protoc-gen-dart="$PLUGIN" \
  "$PROTO_DIR/raccoon/v1/runner.proto"
rm -rf "$(dirname "$PLUGIN")"
