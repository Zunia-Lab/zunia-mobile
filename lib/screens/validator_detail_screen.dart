import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/delegate_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Validator detail for one operator.
class ValidatorDetailScreen extends ConsumerWidget {
  const ValidatorDetailScreen({
    super.key,
    required this.chainId,
    required this.validator,
  });

  final String chainId;
  final ValidatorInfo validator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: validator.moniker,
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: s.glass,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: s.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ZuniaValidatorDetail(
                    name: validator.moniker,
                    moniker: validator.operatorAddress,
                    commission:
                        '${(validator.commission * 100).toStringAsFixed(2)}%',
                    votingPower:
                        '${(validator.votingPower * 100).toStringAsFixed(2)}%',
                    status: validator.jailed ? 'jailed' : 'bonded',
                    actions: ZuniaButton(
                      label: validator.jailed ? 'Jailed' : 'Delegate',
                      onPressed: validator.jailed
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => DelegateScreen(
                                    chainId: chainId,
                                    moniker: validator.moniker,
                                    operatorAddress: validator.operatorAddress,
                                  ),
                                ),
                              ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
