Run these regression suites on macOS with Xcode command line tools:

```
sh tests/run-hid-regressions.sh
sh tests/run-gesture-regressions.sh
sh tests/run-pointer-regressions.sh
```

The gesture suite compiles the production input manager, touch model, and screen
transforms. Synthetic contact reports exercise tap jitter, slow movement, scrolling,
hold-and-drag, cancellation, and physical distances across display rotations and
letterboxing. A recording subclass captures gesture output; hardware entry points
and cursor utilities are replaced so no device access or mouse events are possible.
Hold timing uses injected timestamps rather than sleeps.

The pointer suite also compiles the production cursor utilities. It intercepts
cursor reads and event posting to check click/drop/restoration order, multiple
contacts, cancellation, and momentum scroll coordinates. No events reach macOS.
Actual cross-application scroll routing remains a manual hardware check.

The fixtures were captured from the connected ThinkVision M14t's Wacom digitizer
(USB `2d1f:524c`) on 2026-09-14. Report `0x0c` carries five finger collections;
the secondary interface's report `0x20` carries one. Descriptor files contain
the complete descriptors; element fixtures retain the touchscreen application
collection and the metadata needed by the interpreter, without device identifiers
such as serial numbers or location IDs.
The short input capture contains real touch-down, movement, and lift-off reports.

The tests create real `IOHIDElementRef` objects and use the captured fixture to
provide their metadata and tree relationships. A standalone
`IOHIDElementCreateWithDictionary` object lacks the private descriptor state that
the HID accessors require, so those accessors and incoming values use a small test
adapter. CoreFoundation arrays, dictionaries, numbers, and ownership remain real.
No virtual HID device, Input Monitoring permission, or physical display is needed.

Tagged pointers are disabled so the storage regression detects missing dictionary
ownership/equality callbacks instead of passing because equal small numbers happen
to share a pointer.
