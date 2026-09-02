import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Saved recipients. When [pickMode] is true, tapping a row returns its address.
class AddressBookScreen extends ConsumerWidget {
  const AddressBookScreen({super.key, this.pickMode = false, this.prefixFilter});

  final bool pickMode;
  /// When set, only show contacts whose address starts with `{prefix}1`.
  final String? prefixFilter;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final label = TextEditingController();
    final address = TextEditingController();
    final s = ZuniaSemanticsExt.of(context);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: s.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: s.line),
        ),
        title: Text(
          'Save recipient',
          style: zuniaSans(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: s.fg,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZuniaInput(controller: label, label: 'Label', hint: 'Exchange'),
            const SizedBox(height: 12),
            ZuniaInput(
              controller: address,
              label: 'Address',
              hint: 'cosmos1…',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: zuniaSans(fontSize: 13, color: s.fgMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Save',
              style: zuniaSans(fontSize: 13, color: s.info),
            ),
          ),
        ],
      ),
    );

    if (saved == true && address.text.trim().isNotEmpty) {
      await ref.read(addressBookProvider.notifier).save(
            AddressBookEntry(
              label: label.text.trim().isEmpty
                  ? address.text.trim()
                  : label.text.trim(),
              address: address.text.trim(),
            ),
          );
    }
    label.dispose();
    address.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final all = ref.watch(addressBookProvider);
    final entries = prefixFilter == null
        ? all
        : all
            .where((e) => e.address.startsWith('${prefixFilter!}1'))
            .toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: pickMode ? 'Pick recipient' : 'Address book',
          onBack: () => Navigator.of(context).pop(),
          body: entries.isEmpty
              ? ZuniaEmptyState(
                  title: all.isEmpty
                      ? 'No saved recipients'
                      : 'No matching contacts',
                  description: all.isEmpty
                      ? 'Save an address once and pick it from the send screen '
                          'instead of pasting it again.'
                      : 'No contacts use the ${prefixFilter}1… prefix.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 9),
                  itemBuilder: (_, i) {
                    final entry = entries[i];
                    return Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: pickMode
                            ? () => Navigator.of(context).pop(entry.address)
                            : null,
                        child: Ink(
                          decoration: BoxDecoration(
                            gradient: s.surfaceRaisedGradient,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 30,
                                  height: 30,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    color: s.glass2,
                                  ),
                                  child: Text(
                                    entry.label.isEmpty
                                        ? '?'
                                        : entry.label.characters.first
                                            .toUpperCase(),
                                    style: zuniaMono(fontSize: 11, color: s.fg),
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.label,
                                        overflow: TextOverflow.ellipsis,
                                        style: zuniaSans(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: s.fg,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        truncateAddress(entry.address, left: 12),
                                        style: zuniaMono(
                                          fontSize: 10.5,
                                          color: s.fgMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (pickMode)
                                  Icon(Icons.chevron_right,
                                      size: 18, color: s.fgDim)
                                else ...[
                                  IconButton(
                                    tooltip: 'Copy',
                                    onPressed: () =>
                                        ClipboardGuard.copy(entry.address),
                                    icon: Icon(
                                      Icons.copy_outlined,
                                      size: 16,
                                      color: s.info,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove',
                                    onPressed: () => ref
                                        .read(addressBookProvider.notifier)
                                        .remove(entry.address),
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 16,
                                      color: s.fgDim,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
          footer: pickMode
              ? null
              : ZuniaButton(
                  label: 'Add recipient',
                  size: ZuniaButtonSize.lg,
                  leading: const Icon(Icons.add),
                  onPressed: () => _add(context, ref),
                ),
        ),
      ),
    );
  }
}
