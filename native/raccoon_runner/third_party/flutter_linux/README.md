# flutter_linux, the plugin-facing half

Flutter's Linux embedding, reduced to what a plugin binary links against:
`FlValue`, the codecs, the channel classes, and the `FlBinaryMessenger`,
`FlPluginRegistrar`, `FlTextureRegistrar` and `FlPluginRegistry` interfaces,
with the public headers. Built into a `libflutter_linux_gtk.so` of the
runner's own, same soname, so unmodified plugins load into the runner. The
engine behind it is the runner's: `raccoon/fl_engine.cc` is an `FlEngine`
over a bridge of five calls (`raccoon/fl_raccoon_bridge.h`), and
`flutter/shell/platform/linux/fl_engine_private.h` is ours too, kept to the
declarations the vendored sources use. `raccoon/fl_view.cc` gives the view
type a name; there is no view.

Everything under `flutter/` except `fl_engine_private.h` and
`embedder/embedder.h` is verbatim from flutter/flutter at the revision in
`REVISION`, under `LICENSE`. `tool/vendor_flutter_linux.sh` refreshes it.
