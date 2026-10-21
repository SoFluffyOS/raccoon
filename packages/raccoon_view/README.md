# raccoon_view

Flutter widgets that show an app hosted by the Raccoon runtime inside Lumide:
the frame view, pointer and key forwarding, and the hosted app's text field
mirrored into the host's input method.

On Linux it is a plugin too. When the connection carries GPU buffers, the
native side (`linux/raccoon_view_plugin.cc`) takes the runner's buffers from
its GPU socket, imports them into Flutter's own GL context, waits on each
frame's fence, and the view draws a `Texture`: no pixels copied. It gives
each buffer back to the runner once the next one is bound, with a fence for
its last read. Anywhere else, or on a connection without GPU buffers, frames
are decoded from pixels as before. A host app needs nothing beyond the
plugin registration the Flutter tool generates for any app depending on it.

Imports only `flutter/widgets.dart`. Developed inside the Lumide workspace
(`packages/raccoon_view`) and resolves through it.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every Raccoon repository, whichever piece the bug is in. Issues are off on this one.
