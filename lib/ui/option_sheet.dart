/// Choose one of a few options: the iOS action sheet, or on Android a
/// scrollable bottom sheet of radio rows.
///
/// `showZuniaActionSheet`'s Android sheet is a fixed column inside a sheet
/// capped at 9/16 of the screen, so five options at large text overflow it on
/// a small phone. This keeps the iOS sheet (which scrolls) and gives Android
/// a list that scrolls too. Candidate for promotion into zunia_ui.
library;

import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<({T value, String label})> options,
  T? selected,
  String? message,
}) {
  if (ZuniaPlatform.isCupertino(context)) {
    return showZuniaActionSheet<T>(
      context,
      title: title,
      message: message,
      actions: [
        for (final o in options)
          ZuniaAlertAction(
            label: o.label,
            value: o.value,
            isDefault: o.value == selected,
          ),
      ],
    );
  }
  return showZuniaSheet<T>(
    context,
    title: title,
    builder: (ctx) {
      final s = ZuniaSemanticsExt.of(ctx);
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  message,
                  style: zuniaSans(fontSize: 13, height: 1.4, color: s.fgMuted),
                ),
              ),
            for (final o in options)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: Text(o.label, style: zuniaSans(fontSize: 15, color: s.fg)),
                selected: o.value == selected,
                trailing: Icon(
                  o.value == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: o.value == selected ? s.accent : s.fgDim,
                ),
                onTap: () {
                  ZuniaHaptics.selection();
                  Navigator.of(ctx).pop(o.value);
                },
              ),
          ],
        ),
      );
    },
  );
}
