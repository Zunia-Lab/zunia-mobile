import 'package:zunia_mobile/crypto/wallet_kernel.dart';

/// `skip:` value for tests that need the native kernel on the host.
Object get kernelSkip => WalletKernel.instance.isAvailable
    ? false
    : 'zunia-core host library not built (cargo build -p zunia-ffi --release)';
