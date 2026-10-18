/// The one place every dApp signature passes after the user approves its
/// prompt and before the kernel signs: the in-app browser, Zunia Connect and
/// WalletConnect all call [confirmDappSignature] from the shared review sheet
/// (`native_request_sheets.dart`, `_ReviewSheetState._approve`).
library;

import 'package:flutter/widgets.dart';

/// Returns true when signing may go ahead.
///
/// INTEGRATION POINT (security workstream): extension 0.1.5 can ask for the
/// password on every signature. Once `lib/security/signing_gate.dart` lands,
/// replace the body with its check, e.g.
///
/// ```dart
/// return confirmSigning(context, reason: reason);
/// ```
///
/// and nothing else needs to change: false keeps the prompt open and signs
/// nothing.
Future<bool> confirmDappSignature(
  BuildContext context, {
  required String reason,
}) async {
  return true;
}
