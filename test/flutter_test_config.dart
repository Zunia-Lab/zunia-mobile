import 'dart:async';
import 'dart:io';

import 'package:zunia_core/zunia_core.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

/// Loads the kernel built for this machine before any test runs, so tests
/// sign and derive with the same Rust code the app ships.
///
/// Build it once with `cargo build -p zunia-ffi --release` in ../zunia-core,
/// or point ZUNIA_FFI_LIB at a library. Tests that need the kernel are
/// skipped (see `kernelSkip`) when none is found.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final candidates = [
    Platform.environment['ZUNIA_FFI_LIB'],
    '../zunia-core/target/release/libzunia_ffi.dylib',
    '../zunia-core/target/release/libzunia_ffi.so',
  ];
  for (final path in candidates) {
    if (path == null || !File(path).existsSync()) continue;
    WalletKernel.debugUse(ZuniaCore.openPath(File(path).absolute.path));
    break;
  }
  await testMain();
}
