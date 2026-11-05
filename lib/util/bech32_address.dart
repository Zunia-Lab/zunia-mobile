/// Bech32 address checks shared by the address book, the add-chain form and
/// anything else that has to tell a real address from one with a typo.
///
/// Mirrors `isValidBech32Address` / `bech32PrefixOf` in `@zunialab/interchain`:
/// structure and checksum (BIP-173, never bech32m), lowercase only. The payload
/// length (20 bytes for an account, 32 for a contract) is the kernel's rule and
/// is enforced there before anything is signed.
library;

import 'package:bech32/bech32.dart';

/// The human-readable prefix of a valid address (`cosmos`, `addr_safro`), or
/// null when [value] is not one.
String? bech32PrefixOf(String value) {
  final text = value.trim();
  // Upper case is legal bech32 but no Cosmos wallet prints it, and a mixed or
  // upper-case address pasted from somewhere is more often a mangled one.
  if (text.isEmpty || text != text.toLowerCase()) return null;
  try {
    return const Bech32Codec().decode(text).hrp;
  } on Object {
    return null;
  }
}

/// True when [value] decodes with a valid checksum.
bool isValidBech32Address(String value) => bech32PrefixOf(value) != null;
