import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// A search box in the platform's own shape: `UISearchTextField` on iPhone,
/// a filled Material 3 search field on Android. Clears with one tap.
///
/// Candidate for `zunia_ui`: Home, Activity, Receive and the pickers use it.
class AdaptiveSearchField extends StatelessWidget {
  const AdaptiveSearchField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.onChanged,
  });

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    if (ZuniaPlatform.isCupertino(context)) {
      return CupertinoSearchTextField(
        controller: controller,
        placeholder: placeholder,
        onChanged: onChanged,
        style: zuniaSans(fontSize: 15, color: s.fg),
        placeholderStyle: zuniaSans(fontSize: 15, color: s.fgDim),
        backgroundColor: s.glass2,
        itemColor: s.fgMuted,
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        autocorrect: false,
        style: zuniaSans(fontSize: 14, color: s.fg),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: s.glass2,
          hintText: placeholder,
          hintStyle: zuniaSans(fontSize: 14, color: s.fgDim),
          prefixIcon: Icon(Icons.search, size: 20, color: s.fgMuted),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: Icon(Icons.close, size: 18, color: s.fgMuted),
                  onPressed: () {
                    controller.clear();
                    onChanged?.call('');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
