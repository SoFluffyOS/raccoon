# raccoon_view

Flutter widgets that show an app hosted by the Raccoon runtime inside Lumide:
the frame view, pointer and key forwarding, the hosted app's mouse cursor
(what it activates on `flutter/mousecursor`, shown over the view when the
connection serves channels), and the hosted app's text field mirrored into
the host's input method.

On Linux, macOS and Windows it is a plugin too. When the connection carries GPU
buffers, the native side takes the runner's buffers from its GPU socket and
the view draws a `Texture`: no pixels copied. On Linux
(`linux/raccoon_view_plugin.cc`) the buffers are dmabufs, imported into
Flutter's own GL context, and the plugin waits on each frame's fence. On
macOS (`macos/raccoon_view/Sources/raccoon_view/RaccoonViewPlugin.mm`) they
are IOSurfaces, taken by Mach port from the runner's own service (the
plugin asks on connecting; a runner too old to answer has them looked up
by ID) and wrapped as pixel buffers; the runner names a frame only once its
GPU has drawn it. On Windows (`windows/raccoon_view_plugin.cpp`) they are
shared D3D11 textures, named by handle, which Flutter opens on its own device
as DXGI shared-handle surfaces; there too the runner names a frame once
drawn. Each plugin gives each
buffer back to the runner once the next one is bound, with a fence for its
last read where there are fences. With `spin` on Windows, at 60 Hz, the
runner takes 4–5% of a core and the host app 4–6%, against 22–24% and
93–95% decoding pixels. Anywhere else, or on a connection without
GPU buffers, frames are decoded from pixels as before. A host app needs
nothing beyond the plugin registration the Flutter tool generates for any
app depending on it; the macOS plugin comes as a Swift package and a
podspec, for either way of integrating plugins.

`PluginStubs` answers, on the client, the plugins with no implementation
for the runner's host the way a phone would: `permission_handler`
(granted, denied or permanently denied, as the host says),
`google_mobile_ads` (initialized, never filled), `flutter_foreground_task`
(a service that starts and stops), `vibration` and `sensors_plus` (a device
at rest). Only calls no native plugin took reach the client, so a loaded
plugin is never answered by them; `PluginStubs.plugins` names them, for a
host that warns about plugins whose calls fail.

Uses no Material or Cupertino widgets.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every piece of Raccoon, whichever the bug is in.
