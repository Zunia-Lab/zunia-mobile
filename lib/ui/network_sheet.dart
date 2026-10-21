/// Pick one network from a list: a bottom sheet with search once the list is
/// long, the current choice ticked, and an optional "All networks" row.
/// Candidate for promotion into zunia_ui alongside `ZuniaNetworkPickerSheet`,
/// which takes a different row shape.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Returned for the "All networks" row.
const allNetworks = '*';

Future<String?> pickNetwork(
  BuildContext context, {
  required List<ChainEntry> chains,
  required String? selected,
  String title = 'Network',
  bool allowAll = false,
}) {
  return showZuniaSheet<String>(
    context,
    title: title,
    builder: (ctx) => _NetworkList(
      chains: chains,
      selected: selected,
      allowAll: allowAll,
    ),
  );
}

class _NetworkList extends StatefulWidget {
  const _NetworkList({
    required this.chains,
    required this.selected,
    required this.allowAll,
  });

  final List<ChainEntry> chains;
  final String? selected;
  final bool allowAll;

  @override
  State<_NetworkList> createState() => _NetworkListState();
}

class _NetworkListState extends State<_NetworkList> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(String id) {
    ZuniaHaptics.selection();
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final rows = widget.chains.where((c) => c.matches(_query)).toList();
    final height = MediaQuery.sizeOf(context).height * 0.62;

    Widget tick(bool on) => on
        ? Icon(
            cupertino ? CupertinoIcons.check_mark : Icons.check,
            size: 20,
            color: s.accent,
          )
        : const SizedBox(width: 20);

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.chains.length > 7) ...[
            ZuniaSearchField(
              controller: _search,
              hintText: 'Search networks',
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: ListView(
              children: [
                if (widget.allowAll && _query.trim().isEmpty)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(Icons.public, color: s.fgMuted),
                    title: Text(
                      'All networks',
                      style: zuniaSans(fontSize: 15, color: s.fg),
                    ),
                    subtitle: Text(
                      '${widget.chains.length} enabled',
                      style: zuniaMono(fontSize: 11, color: s.fgDim),
                    ),
                    trailing: tick(widget.selected == null ||
                        widget.selected == allNetworks),
                    onTap: () => _pick(allNetworks),
                  ),
                for (final chain in rows)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: ChainAvatar(chain: chain, size: 30),
                    title: Text(
                      chain.chainName,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(fontSize: 15, color: s.fg),
                    ),
                    subtitle: Text(
                      chain.chainId,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 11, color: s.fgDim),
                    ),
                    trailing: tick(chain.chainId == widget.selected),
                    selected: chain.chainId == widget.selected,
                    onTap: () => _pick(chain.chainId),
                  ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No network matches “${_query.trim()}”.',
                      textAlign: TextAlign.center,
                      style: zuniaSans(fontSize: 13, color: s.fgMuted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The compact control that opens [pickNetwork]: logo, name, chevron.
class NetworkChipButton extends StatelessWidget {
  const NetworkChipButton({
    super.key,
    required this.chain,
    required this.onTap,
    this.label,
  });

  /// Null shows [label] (e.g. "All networks") with a globe.
  final ChainEntry? chain;
  final String? label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final name = chain?.chainName ?? label ?? 'Network';
    return Semantics(
      button: true,
      label: 'Network: $name. Change',
      child: Material(
        color: s.glass,
        shape: StadiumBorder(side: BorderSide(color: s.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (chain != null)
                    ChainAvatar(chain: chain!, size: 24)
                  else
                    Icon(Icons.public, size: 20, color: s.fgMuted),
                  const SizedBox(width: 8),
                  Flexible(
                    child: ExcludeSemantics(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: s.fg,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.expand_more, size: 18, color: s.fgMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
