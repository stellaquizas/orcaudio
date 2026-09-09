# Original dictation icons

The icon uses original geometric voice bars and an abstract whale-tail motif on a black/silver tile. It does not contain the official Orca vector mark. The product name identifies it as an Orca companion; this is not an official Orca app icon.

Rebuild assets:

```sh
xcrun swiftc -parse-as-library scripts/IconRenderer.swift -o build/IconRenderer
build/IconRenderer
iconutil -c icns build/AppIcon.iconset -o Assets/AppIcon.icns
./build.sh
```

AppIcon.icns contains 16–1024 pixel representations. The menu template has 1x and 2x resources and uses native light/dark appearance, with red tint during recording.
