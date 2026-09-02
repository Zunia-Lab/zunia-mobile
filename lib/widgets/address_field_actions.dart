import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Compact QR + address-book actions for recipient fields.
class AddressFieldActions extends StatelessWidget {
  const AddressFieldActions({
    super.key,
    required this.onScan,
    required this.onBook,
  });

  final VoidCallback onScan;
  final VoidCallback onBook;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Scan QR',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: onScan,
          icon: Icon(Icons.qr_code_scanner, size: 20, color: s.fgMuted),
        ),
        IconButton(
          tooltip: 'Address book',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: onBook,
          icon: Icon(Icons.menu_book_outlined, size: 20, color: s.fgMuted),
        ),
      ],
    );
  }
}
