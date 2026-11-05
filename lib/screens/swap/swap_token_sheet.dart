/// The token picker: a native sheet with search over every name a token goes
/// by, the wallet's own tokens first.
///
/// Rows that cannot be picked for the current From are kept out of the list
/// and shown only to a search, each with the reason, the same rule the
/// extension's picker follows: nobody is left wondering why the token they
/// typed is missing.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zunia_mobile/screens/swap/swap_widgets.dart';
import 'package:zunia_mobile/swap/swap_amounts.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Open the picker; resolves the picked row's key, or null when dismissed.
Future<String?> showSwapTokenSheet(
  BuildContext context, {
  required String title,
  required List<SwapAsset> options,
  String? selectedKey,
  bool hideAmounts = false,
}) {
  return showZuniaSheet<String>(
    context,
    title: title,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.72,
      child: SwapTokenList(
        options: options,
        selectedKey: selectedKey,
        hideAmounts: hideAmounts,
        onPick: (key) => Navigator.of(ctx).pop(key),
      ),
    ),
  );
}

/// The searchable list inside the sheet. Public so it can be tested alone.
class SwapTokenList extends StatefulWidget {
  const SwapTokenList({
    super.key,
    required this.options,
    required this.onPick,
    this.selectedKey,
    this.hideAmounts = false,
  });

  final List<SwapAsset> options;
  final ValueChanged<String> onPick;
  final String? selectedKey;
  final bool hideAmounts;

  @override
  State<SwapTokenList> createState() => _SwapTokenListState();
}

sealed class _Item {}

class _Header extends _Item {
  _Header(this.text);
  final String text;
}

class _Row extends _Item {
  _Row(this.asset);
  final SwapAsset asset;
}

class _SwapTokenListState extends State<SwapTokenList> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<_Item> _items() {
    final query = _query.text.trim();
    if (query.isNotEmpty) {
      final hits = [
        for (final a in widget.options)
          if (a.matches(query)) a,
      ];
      return [for (final a in hits) _Row(a)];
    }
    final held = <SwapAsset>[];
    final reachable = <SwapAsset>[];
    final more = <SwapAsset>[];
    for (final asset in widget.options) {
      if (asset.searchOnly) continue;
      if (asset.held) {
        held.add(asset);
      } else if (asset.executable == Executable.yes) {
        reachable.add(asset);
      } else {
        more.add(asset);
      }
    }
    return [
      if (held.isNotEmpty) ...[
        _Header('Your tokens'),
        for (final a in held) _Row(a),
      ],
      if (reachable.isNotEmpty) ...[
        _Header('One signature through the swap contract'),
        for (final a in reachable) _Row(a),
      ],
      if (more.isNotEmpty) ...[
        _Header('More tokens'),
        for (final a in more) _Row(a),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final items = _items();
    final hidden = widget.options.where((a) => a.searchOnly).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ZuniaPlatform.isCupertino(context))
          CupertinoSearchTextField(
            controller: _query,
            placeholder: 'Search tokens and networks',
            onChanged: (_) => setState(() {}),
            style: zuniaSans(fontSize: 15, color: s.fg),
          )
        else
          TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            style: zuniaSans(fontSize: 15, color: s.fg),
            decoration: InputDecoration(
              hintText: 'Search tokens and networks',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: s.glass,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
        const SizedBox(height: 10),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: ZuniaEmptyState(
                    title: 'Nothing matches',
                    description: _query.text.trim().isEmpty
                        ? 'There is nothing to pick here yet.'
                        : 'No token or network goes by "${_query.text.trim()}".',
                  ),
                )
              : ListView.builder(
                  itemCount:
                      items.length +
                      (hidden > 0 && _query.text.trim().isEmpty ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == items.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                        child: Text(
                          '$hidden more cannot be picked for this swap. Search to see each one and why.',
                          style: zuniaSans(
                            fontSize: 12,
                            height: 1.4,
                            color: s.fgDim,
                          ),
                        ),
                      );
                    }
                    final item = items[index];
                    return switch (item) {
                      _Header(:final text) => Padding(
                        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                        child: Semantics(
                          header: true,
                          child: Text(
                            text.toUpperCase(),
                            style: zuniaMono(
                              fontSize: 10.5,
                              letterSpacing: 0.8,
                              color: s.fgDim,
                            ),
                          ),
                        ),
                      ),
                      _Row(:final asset) => _TokenRow(
                        asset: asset,
                        selected: asset.key == widget.selectedKey,
                        hideAmounts: widget.hideAmounts,
                        onTap: asset.disabledReason != null
                            ? null
                            : () {
                                ZuniaHaptics.selection();
                                widget.onPick(asset.key);
                              },
                      ),
                    };
                  },
                ),
        ),
      ],
    );
  }
}

class _TokenRow extends StatelessWidget {
  const _TokenRow({
    required this.asset,
    required this.selected,
    required this.hideAmounts,
    required this.onTap,
  });

  final SwapAsset asset;
  final bool selected;
  final bool hideAmounts;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final disabled = onTap == null;
    final identity = asset.identity;
    final subtitle = asset.disabledReason ?? identity.subtitle;
    final balance = asset.held
        ? hideAmounts
              ? '••••'
              : swapAmountText(asset.amount, identity)
        : null;
    return Semantics(
      container: true,
      button: !disabled,
      enabled: !disabled,
      selected: selected,
      label:
          '${identity.ticker} on ${asset.chainName}'
          '${balance == null ? '' : ', balance $balance'}'
          '${asset.disabledReason == null ? '' : '. ${asset.disabledReason}'}',
      excludeSemantics: true,
      child: Material(
        color: selected ? s.stateSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Opacity(
                opacity: disabled ? 0.55 : 1,
                child: Row(
                  children: [
                    SwapTokenMark(
                      identity: identity,
                      chainIconUrl: asset.chainIconUrl,
                      size: 34,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            identity.ticker,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: zuniaSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: s.fg,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: zuniaSans(
                              fontSize: 12,
                              height: 1.3,
                              color: asset.disabledReason != null
                                  ? s.warning
                                  : s.fgMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (balance != null) ...[
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          balance,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: zuniaMono(fontSize: 12.5, color: s.fg),
                        ),
                      ),
                    ],
                    if (selected) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check, size: 18, color: s.accent),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
