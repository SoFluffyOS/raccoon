# raccoon_view

Flutter widgets that show an app hosted by the Raccoon runtime inside Lumide:
the frame view, pointer and key forwarding, the hosted app's mouse cursor
(what it activates on `flutter/mousecursor`, shown over the view when the
connection serves channels), and the hosted app's text field mirrored into
the host's input method.

On Linux and macOS it is a plugin too. When the connection carries GPU
buffers, the native side takes the runner's buffers from its GPU socket and
the view draws a `Texture`: no pixels copied. On Linux
(`linux/raccoon_view_plugin.cc`) the buffers are dmabufs, imported into
Flutter's own GL context, and the plugin waits on each frame's fence. On
macOS (`macos/raccoon_view/Sources/raccoon_view/RaccoonViewPlugin.mm`) they
are IOSurfaces, looked up by ID and wrapped as pixel buffers; the runner
names a frame only once its GPU has drawn it. Either plugin gives each
buffer back to the runner once the next one is bound, with a fence for its
last read where there are fences. Anywhere else, or on a connection without
GPU buffers, frames are decoded from pixels as before. A host app needs
nothing beyond the plugin registration the Flutter tool generates for any
app depending on it; the macOS plugin comes as a Swift package and a
podspec, for either way of integrating plugins.

Imports only `flutter/widgets.dart`. Developed inside the Lumide workspace
(`packages/raccoon_view`) and resolves through it.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every Raccoon repository, whichever piece the bug is in. Issues are off on this one.
