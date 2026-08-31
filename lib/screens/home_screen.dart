import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zunia_mobile/theme/zunia_theme.dart';
import 'package:zunia_mobile/widgets/zunia_widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Image.asset(
                      'assets/brand/icon.png',
                      width: 36,
                      height: 36,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'zunia',
                      style: zuniaSans(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.8,
                        color: ZuniaColors.paper,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  'One wallet for\nevery Cosmos chain.',
                  style: zuniaSans(
                    fontSize: 34,
                    fontWeight: FontWeight.w500,
                    height: 1.12,
                    letterSpacing: -1.2,
                    color: ZuniaColors.paper,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Non-custodial. IBC-native. Same keys as the browser extension.',
                  style: zuniaSans(
                    fontSize: 16,
                    height: 1.5,
                    color: ZuniaColors.muted,
                  ),
                ),
                const SizedBox(height: 28),
                const ZuniaSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ZuniaLabel('Demo portfolio'),
                      SizedBox(height: 10),
                      ZuniaAmount(value: '612.40', denom: 'ATOM'),
                      SizedBox(height: 8),
                      ZuniaAddress(
                        value: 'cosmos1abcdefghijklmnopqrstuvwxyz012345',
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () {},
                  child: const Text('Create wallet'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {},
                  child: const Text('Import recovery phrase'),
                ),
                const SizedBox(height: 16),
                Text(
                  'iOS · Android · Flutter',
                  textAlign: TextAlign.center,
                  style: zuniaMono(
                    fontSize: 11,
                    color: ZuniaColors.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
