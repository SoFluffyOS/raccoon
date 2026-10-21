#!/usr/bin/env bash
# Regenerates lib/src/proto from the runner's proto files. Needs protoc and
# the Dart plugin (dart pub global activate protoc_plugin).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="${RACCOON_PROTO_DIR:-$ROOT/../../native/raccoon_runner/proto}"
PROTOC="${PROTOC:-$HOME/.local/raccoon/protoc/bin/protoc}"
"$PROTOC" -I "$PROTO_DIR" --dart_out="$ROOT/lib/src/proto" \
  --plugin=protoc-gen-dart="$HOME/.pub-cache/bin/protoc-gen-dart" \
  "$PROTO_DIR/raccoon/v1/runner.proto"
