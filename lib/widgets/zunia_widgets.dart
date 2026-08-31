import 'package:flutter/material.dart';
import 'package:zunia_mobile/theme/zunia_theme.dart';

class ZuniaSurface extends StatelessWidget {
  const ZuniaSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ZuniaThemeTokens.darkElevated,
        borderRadius: BorderRadius.circular(ZuniaRadii.lg),
        border: Border.all(color: const Color(0x1FF4F5F7)),
      ),
      child: child,
    );
  }
}

class ZuniaLabel extends StatelessWidget {
  const ZuniaLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: zuniaSans(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: ZuniaColors.muted,
      ),
    );
  }
}

class ZuniaAmount extends StatelessWidget {
  const ZuniaAmount({super.key, required this.value, this.denom});

  final String value;
  final String? denom;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: value,
            style: zuniaMono(
              fontSize: 22,
              fontWeight: FontWeight.w500,
              color: ZuniaColors.paper,
            ),
          ),
          if (denom != null)
            TextSpan(
              text: ' $denom',
              style: zuniaMono(
                fontSize: 14,
                color: ZuniaColors.muted,
              ),
            ),
        ],
      ),
    );
  }
}

class ZuniaAddress extends StatelessWidget {
  const ZuniaAddress({super.key, required this.value, this.keep = 8});

  final String value;
  final int keep;

  String get _truncated {
    if (value.length <= keep * 2 + 1) return value;
    return '${value.substring(0, keep)}…${value.substring(value.length - keep)}';
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _truncated,
      style: zuniaMono(
        fontSize: 12,
        color: ZuniaColors.muted,
      ),
    );
  }
}
