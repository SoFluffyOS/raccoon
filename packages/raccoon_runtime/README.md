# raccoon_runtime

The host side of the Raccoon runtime, as Lumide uses it: the
runtime store, runner process management and discovery, the custom-device
configuration, and the frame and input client. Pure Dart, no Flutter, so
`lumide_server` and command-line tools can share it.

This package is developed inside the Lumide workspace (`packages/raccoon_runtime`)
and resolves through it.
