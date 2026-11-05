/// Help, from the drawer: where the guides are and how to reach the team.
///
/// The support page carries the guides and the only two contact addresses;
/// a report goes to the public tracker, where a version and steps can be
/// attached. Every link opens in the system browser or mail app.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/config/app_identity.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Where help lives. Checked to answer on 2026-11-05.
abstract final class HelpLinks {
  static final support = Uri.parse('https://zunialab.com/support');
  static final guide = Uri.parse('https://docs.zunialab.com/docs/use-wallet/mobile/');
  static final report = Uri.parse('https://updates.zunialab.com/requests/new');
  static final email = Uri.parse('mailto:dev@zunialab.com?subject=Zunia%20Mobile%20$appVersion');
}

/// Opens the Help sheet over [context].
Future<void> showHelpSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const HelpSheet(),
    );

class HelpSheet extends StatelessWidget {
  const HelpSheet({super.key});

  Future<void> _open(BuildContext context, Uri uri) async {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not open ${uri.scheme == 'mailto' ? 'the mail app' : uri.host}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    IconData icon(IconData material, IconData ios) => cupertino ? ios : material;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.sheetGradient,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: s.lineStrong)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.lineStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Help',
                style: zuniaSans(fontSize: 17, fontWeight: FontWeight.w500, color: s.fg),
              ),
              const SizedBox(height: 12),
              ZuniaListTile(
                title: 'Help center',
                subtitle: 'Guides and answers',
                leading: icon(Icons.support_agent, CupertinoIcons.question_circle),
                navigates: true,
                onTap: () => _open(context, HelpLinks.support),
              ),
              ZuniaListTile(
                title: 'Mobile guide',
                subtitle: 'Send, swap, stake and connect, step by step',
                leading: icon(Icons.menu_book_outlined, CupertinoIcons.book),
                navigates: true,
                onTap: () => _open(context, HelpLinks.guide),
              ),
              ZuniaListTile(
                title: 'Report a problem',
                subtitle: 'Mention Zunia v$appVersion and what you saw',
                leading: icon(Icons.bug_report_outlined, CupertinoIcons.exclamationmark_bubble),
                navigates: true,
                onTap: () => _open(context, HelpLinks.report),
              ),
              ZuniaListTile(
                title: 'Email support',
                subtitle: 'dev@zunialab.com',
                leading: icon(Icons.mail_outline, CupertinoIcons.mail),
                navigates: true,
                onTap: () => _open(context, HelpLinks.email),
              ),
              const SizedBox(height: 14),
              Text(
                'Zunia never asks for your recovery phrase.',
                textAlign: TextAlign.center,
                style: zuniaSans(fontSize: 12, color: s.fgMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
