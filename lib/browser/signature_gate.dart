/// The one place every dApp signature passes after the user approves its
/// prompt and before the kernel signs: the in-app browser, Zunia Connect and
/// WalletConnect all call [confirmDappSignature] from the shared review sheet
/// (`native_request_sheets.dart`, `_ReviewSheetState._approve`).
library;

import 'package:flutter/widgets.dart';
import 'package:zunia_mobile/security/signing_gate.dart';

/// Returns true when signing may go ahead: at once unless the user turned on
/// "Password on every signature", then after biometrics or the password
/// (`lib/security/signing_gate.dart`). False keeps the prompt open and signs
/// nothing.
Future<bool> confirmDappSignature(
  BuildContext context, {
  required String reason,
}) {
  return SigningGate.confirm(reason: reason);
}
