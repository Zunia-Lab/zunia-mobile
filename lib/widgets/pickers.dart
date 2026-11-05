/// Searchable pickers in a bottom sheet: networks, tokens and contacts.
///
/// A popup menu cannot hold 300 networks; a sheet with a search field and a
/// lazily built list can, and it is what both platforms use for a long choice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/search_field.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// One network row in [showChainSheet].
class ChainOption {
  const ChainOption({required this.chain, this.trailing});

  final ChainEntry chain;

  /// Balance or reach, right-aligned.
  final String? trailing;
}

Future<String?> showChainSheet(
  BuildContext context, {
  required String title,
  required List<ChainOption> options,
  String? selectedId,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _PickerSheet<ChainOption>(
        title: title,
        items: options,
        placeholder: 'Search networks',
        matches: (option, query) => option.chain.matches(query),
        isSelected: (option) => option.chain.chainId == selectedId,
        idOf: (option) => option.chain.chainId,
        empty: 'No network matches',
        row: (context, option, selected) {
          final s = ZuniaSemanticsExt.of(context);
          return Row(
            children: [
              ChainAvatar(chain: option.chain, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.chain.chainName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg),
                    ),
                    Text(
                      option.chain.chainId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                    ),
                  ],
                ),
              ),
              if (option.trailing != null)
                Flexible(
                  child: Text(
                    option.trailing!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: zuniaMono(fontSize: 11, color: s.fgMuted),
                  ),
                ),
              if (selected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check, size: 20, color: s.accent),
              ],
            ],
          );
        },
      ),
    );

/// One token row in [showTokenSheet].
class TokenOption {
  const TokenOption({required this.identity, required this.amount, required this.amountKnown});

  final TokenIdentity identity;

  /// Base units held.
  final String amount;
  final bool amountKnown;
}

Future<String?> showTokenSheet(
  BuildContext context, {
  required List<TokenOption> options,
  String? selectedDenom,
  bool hidden = false,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _PickerSheet<TokenOption>(
        title: 'Choose an asset',
        items: options,
        placeholder: 'Search a ticker, chain or denom',
        matches: (option, query) {
          final haystack = tokenKeywords(option.identity).join(' ').toLowerCase();
          return query.toLowerCase().split(RegExp(r'\s+')).every(haystack.contains);
        },
        isSelected: (option) => option.identity.denom == selectedDenom,
        idOf: (option) => option.identity.denom,
        empty: 'No asset on this network matches',
        row: (context, option, selected) {
          final s = ZuniaSemanticsExt.of(context);
          final amount = option.amountKnown
              ? formatTokenAmount(option.amount, AmountScale.of(option.identity), TokenAmountVariant.picker,
                  hidden: hidden)
              : '—';
          return Semantics(
            label: '${tokenText(option.identity, TokenTextVariant.a11y)}, $amount',
            excludeSemantics: true,
            child: Row(
              children: [
                TokenAvatar(identity: option.identity, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TokenTicker.of(option.identity),
                      Text(
                        tokenText(option.identity, TokenTextVariant.row),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(fontSize: 12, color: s.fgMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    amount,
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    style: zuniaMono(fontSize: 11, color: s.fgMuted),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.check, size: 20, color: s.accent),
                ],
              ],
            ),
          );
        },
      ),
    );

/// Saved recipients whose address fits [expectedPrefix]; returns an address.
Future<String?> showContactSheet(
  BuildContext context,
  WidgetRef ref, {
  required String? expectedPrefix,
}) {
  final contacts = [
    for (final entry in ref.read(addressBookProvider))
      if (expectedPrefix == null || entry.address.startsWith('${expectedPrefix}1')) entry,
  ];
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => _PickerSheet<AddressBookEntry>(
      title: 'Address book',
      items: contacts,
      placeholder: 'Search contacts',
      matches: (entry, query) =>
          '${entry.label} ${entry.address}'.toLowerCase().contains(query.toLowerCase()),
      isSelected: (_) => false,
      idOf: (entry) => entry.address,
      empty: expectedPrefix == null
          ? 'No saved addresses yet'
          : 'No saved ${expectedPrefix}1… addresses',
      footer: TextButton.icon(
        onPressed: () async {
          final picked = await Navigator.of(sheetContext).push<String>(
            MaterialPageRoute(
              builder: (_) => AddressBookScreen(pickMode: true, prefixFilter: expectedPrefix),
            ),
          );
          if (picked != null && sheetContext.mounted) Navigator.of(sheetContext).pop(picked);
        },
        icon: const Icon(Icons.contacts_outlined, size: 18),
        label: const Text('Manage address book'),
      ),
      row: (context, entry, _) {
        final s = ZuniaSemanticsExt.of(context);
        return Row(
          children: [
            ZuniaWalletAvatar(seed: entry.address, size: 32, semanticLabel: entry.label),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg),
                  ),
                  Text(
                    truncateAddress(entry.address, left: 12, right: 6),
                    style: zuniaMono(fontSize: 11, color: s.fgMuted),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _PickerSheet<T> extends StatefulWidget {
  const _PickerSheet({
    required this.title,
    required this.items,
    required this.placeholder,
    required this.matches,
    required this.isSelected,
    required this.idOf,
    required this.row,
    required this.empty,
    this.footer,
  });

  final String title;
  final List<T> items;
  final String placeholder;
  final bool Function(T item, String query) matches;
  final bool Function(T item) isSelected;
  final String Function(T item) idOf;
  final Widget Function(BuildContext context, T item, bool selected) row;
  final String empty;
  final Widget? footer;

  @override
  State<_PickerSheet<T>> createState() => _PickerSheetState<T>();
}

class _PickerSheetState<T> extends State<_PickerSheet<T>> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final query = _search.text.trim();
    final visible = query.isEmpty
        ? widget.items
        : [for (final item in widget.items) if (widget.matches(item, query)) item];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              widget.title,
              style: zuniaSans(fontSize: 18, fontWeight: FontWeight.w500, color: s.fg),
            ),
          ),
          if (widget.items.length > 6)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: AdaptiveSearchField(
                controller: _search,
                placeholder: widget.placeholder,
                onChanged: (_) => setState(() {}),
              ),
            ),
          Expanded(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.empty,
                      textAlign: TextAlign.center,
                      style: zuniaSans(fontSize: 13, color: s.fgMuted),
                    ),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final item = visible[index];
                      final selected = widget.isSelected(item);
                      return InkWell(
                        onTap: () {
                          ZuniaHaptics.selection();
                          Navigator.of(context).pop(widget.idOf(item));
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          child: widget.row(context, item, selected),
                        ),
                      );
                    },
                  ),
          ),
          if (widget.footer != null)
            SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(8), child: widget.footer)),
        ],
      ),
    );
  }
}
