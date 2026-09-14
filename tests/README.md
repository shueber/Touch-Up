Run `sh tests/run-hid-regressions.sh` on macOS with Xcode command line tools.

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
