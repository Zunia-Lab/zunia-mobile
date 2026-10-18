import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Password entry with a show / hide control, styled like `ZuniaInput`.
///
/// Unlike `ZuniaInput` it takes a focus node and an input action, and it
/// keeps the keyboard from learning what is typed: no suggestions, no
/// autocorrect, no personalised learning on Android keyboards.
class ZuniaPasswordField extends StatefulWidget {
  const ZuniaPasswordField({
    super.key,
    required this.controller,
    this.label,
    this.hint = 'Password',
    this.errorText,
    this.focusNode,
    this.autofocus = false,
    this.enabled = true,
    this.newPassword = false,
    this.textInputAction = TextInputAction.done,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? label;
  final String hint;
  final String? errorText;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool enabled;

  /// A password being chosen (autofill offers to generate and save one)
  /// rather than one being entered.
  final bool newPassword;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<ZuniaPasswordField> createState() => _ZuniaPasswordFieldState();
}

class _ZuniaPasswordFieldState extends State<ZuniaPasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final toggle = Semantics(
      button: true,
      label: _visible ? 'Hide password' : 'Show password',
      excludeSemantics: true,
      child: IconButton(
        onPressed: widget.enabled
            ? () => setState(() => _visible = !_visible)
            : null,
        icon: Icon(
          _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 20,
          color: s.fgMuted,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgMuted),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          obscureText: !_visible,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: widget.textInputAction,
          autofillHints: [
            widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
          ],
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          style: zuniaMono(fontSize: 13, color: s.fg),
          decoration: InputDecoration(
            hintText: widget.hint,
            errorText: widget.errorText,
            errorMaxLines: 3,
            suffixIcon: toggle,
          ),
        ),
      ],
    );
  }
}
