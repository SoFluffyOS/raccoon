#!/bin/sh
# Fetches the plugin-facing half of Flutter's Linux embedding at one engine
# revision into third_party/flutter_linux: the value, codec and channel
# classes, the messenger, registrar and texture interfaces, and the public
# headers. The runner builds them into a libflutter_linux_gtk.so of its own
# that plugin binaries link against; the engine behind it is the runner's.
#
#   tool/vendor_flutter_linux.sh [engine-revision]
#
# Without a revision, the one of the Flutter SDK on the PATH is used.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/third_party/flutter_linux"
rev="${1:-}"
if [ -z "$rev" ]; then
  flutter_bin="$(command -v flutter)"
  sdk="$(cd "$(dirname "$(readlink -f "$flutter_bin")")/.." && pwd)"
  rev="$(cat "$sdk/bin/internal/engine.version")"
fi
base="https://raw.githubusercontent.com/flutter/flutter/$rev/engine/src/flutter"
linux="$out/flutter/shell/platform/linux"
sources="fl_basic_message_channel.cc fl_binary_codec.cc fl_binary_messenger.cc
fl_binary_messenger_private.h fl_event_channel.cc fl_json_message_codec.cc
fl_json_method_codec.cc fl_message_codec.cc fl_method_call.cc
fl_method_call_private.h fl_method_channel.cc fl_method_channel_private.h
fl_method_codec.cc fl_method_codec_private.h fl_method_response.cc
fl_pixel_buffer_texture.cc fl_pixel_buffer_texture_private.h
fl_plugin_registrar.cc fl_plugin_registrar_private.h fl_plugin_registry.cc
fl_standard_message_codec.cc fl_standard_method_codec.cc fl_string_codec.cc
fl_texture.cc fl_texture_gl.cc fl_texture_gl_private.h fl_texture_private.h
fl_texture_registrar.cc fl_texture_registrar_private.h fl_value.cc"
headers="fl_application.h fl_basic_message_channel.h fl_binary_codec.h
fl_binary_messenger.h fl_dart_project.h fl_engine.h fl_event_channel.h
fl_json_message_codec.h fl_json_method_codec.h fl_message_codec.h
fl_method_call.h fl_method_channel.h fl_method_codec.h fl_method_response.h
fl_pixel_buffer_texture.h fl_plugin_registrar.h fl_plugin_registry.h
fl_standard_message_codec.h fl_standard_method_codec.h fl_string_codec.h
fl_texture.h fl_texture_gl.h fl_texture_registrar.h fl_value.h fl_view.h
flutter_linux.h"
mkdir -p "$linux/public/flutter_linux"
for f in $sources; do
  curl -fsSL "$base/shell/platform/linux/$f" -o "$linux/$f"
done
for h in $headers; do
  curl -fsSL "$base/shell/platform/linux/public/flutter_linux/$h" -o "$linux/public/flutter_linux/$h"
done
curl -fsSL "https://raw.githubusercontent.com/flutter/flutter/$rev/LICENSE" -o "$out/LICENSE"
echo "$rev" > "$out/REVISION"
echo "vendored flutter_linux at $rev"
