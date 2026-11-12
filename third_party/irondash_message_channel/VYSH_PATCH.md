# irondash_message_channel 0.7.0

Upstream: https://pub.dev/packages/irondash_message_channel/versions/0.7.0
The upstream MIT license is preserved in LICENSE.

Rust's `register_isolate(port, *mut c_void)` uses the pointer value as an opaque
isolate ID. The upstream Dart binding passes `Handle`, whose address is a
temporary native call slot. Flutter engines sharing a platform thread can
therefore receive the same ID, overwrite each other's message ports and reuse
the wrong drag/drop context.

The FFI binding now takes a native pointer matching Rust's signature. Each
isolate owns a stable one-byte native allocation, released by NativeFinalizer.
The public Dart channel API and Rust wire protocol are unchanged.
