import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/network_sheet.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/util/bech32_address.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

String? _chainName(String chainId) => ChainCatalog.isLoaded
    ? ChainCatalog.instance.find(chainId)?.chainName
    : null;

/// "Sent 3 times, last 2d ago".
String? contactUsage(AddressBookEntry contact, {DateTime? now}) {
  final last = contact.lastUsedAt;
  if (last == null || contact.useCount == 0) return null;
  final times = contact.useCount == 1 ? 'once' : '${contact.useCount} times';
  final diff = (now ?? DateTime.now())
      .difference(DateTime.fromMillisecondsSinceEpoch(last));
  final when = diff.inDays >= 1
      ? '${diff.inDays}d ago'
      : diff.inHours >= 1
          ? '${diff.inHours}h ago'
          : 'just now';
  return 'Sent $times, last $when';
}

/// Saved recipients: favourites first, search, add and edit in a sheet.
///
/// With [pickMode] a tap returns the address (Send, NFT transfer, IBC):
/// only contacts usable on the target show, by [prefixFilter] (exact bech32
/// prefix) and [chainId] (a contact pinned to another network is left out).
class AddressBookScreen extends ConsumerStatefulWidget {
  const AddressBookScreen({
    super.key,
    this.pickMode = false,
    this.prefixFilter,
    this.chainId,
  });

  final bool pickMode;
  final String? prefixFilter;
  final String? chainId;

  @override
  ConsumerState<AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends ConsumerState<AddressBookScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _edit(AddressBookEntry? contact) {
    showZuniaSheet<void>(
      context,
      title: contact == null ? 'New contact' : 'Edit contact',
      builder: (_) => ContactSheet(contact: contact),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final all = ref.watch(addressBookProvider);
    final scoped = widget.pickMode
        ? contactsFor(all, prefix: widget.prefixFilter, chainId: widget.chainId)
        : all;
    final results = searchContacts(scoped, _query, chainName: _chainName);
    final searching = _query.trim().isNotEmpty;
    final favorites = searching
        ? const <AddressBookEntry>[]
        : results.where((c) => c.favorite).toList();
    final recent = widget.pickMode && !searching
        ? recentContacts(results.where((c) => !c.favorite).toList(), limit: 3)
        : const <AddressBookEntry>[];

    Widget row(AddressBookEntry c) => _ContactRow(
          contact: c,
          pickMode: widget.pickMode,
          onTap: widget.pickMode
              ? () => Navigator.of(context).pop(c.address)
              : () => _edit(c),
          onFavorite: () => unawaited(
            ref.read(addressBookProvider.notifier).toggleFavorite(c.id),
          ),
        );

    List<Widget> group(String title, List<AddressBookEntry> rows) => [
          if (rows.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Semantics(
                  header: true,
                  child: Text(
                    cupertino ? title.toUpperCase() : title,
                    style: cupertino
                        ? zuniaSans(fontSize: 12.5, color: s.fgDim)
                        : zuniaSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: s.accent,
                          ),
                  ),
                ),
              ),
            ),
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) => row(rows[i]),
          ),
        ];

    return ZuniaLargeTitleScaffold(
      title: widget.pickMode ? 'Choose recipient' : 'Address book',
      actions: [
        IconButton(
          tooltip: 'Add contact',
          onPressed: () => _edit(null),
          icon: Icon(cupertino ? CupertinoIcons.add : Icons.person_add_alt, color: s.fg),
        ),
      ],
      slivers: [
        if (all.length >= 4)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            sliver: SliverToBoxAdapter(
              child: ZuniaSearchField(
                controller: _search,
                hintText: 'Search name, address, note or network',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
        if (all.isEmpty)
          SliverToBoxAdapter(
            child: ZuniaEmptyState(
              title: 'No saved addresses',
              description: 'Save an address once and pick it when sending, '
                  'instead of pasting it again.',
              action: ZuniaButton(
                label: 'Add contact',
                variant: ZuniaButtonVariant.secondary,
                size: ZuniaButtonSize.sm,
                onPressed: () => _edit(null),
              ),
            ),
          )
        else if (results.isEmpty)
          SliverToBoxAdapter(
            child: ZuniaEmptyState(
              title: searching ? 'No match' : 'No contact for this network',
              description: searching
                  ? 'No saved address matches “${_query.trim()}”.'
                  : widget.prefixFilter == null
                      ? 'None of your contacts can be used here.'
                      : 'None of your contacts uses ${widget.prefixFilter}1… '
                          'addresses.',
            ),
          )
        else ...[
          ...group('Favourites', favorites),
          ...group('Recent', recent),
          ...group(
            searching ? 'Results' : 'All',
            [
              for (final c in results)
                if (searching || (!c.favorite && !recent.contains(c))) c,
            ],
          ),
        ],
      ],
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.pickMode,
    required this.onTap,
    required this.onFavorite,
  });

  final AddressBookEntry contact;
  final bool pickMode;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final c = contact;
    final network = c.chainId == null ? null : (_chainName(c.chainId!) ?? c.chainId);
    final detail = !c.isValid
        ? 'This address fails its checksum. Fix it or delete it.'
        : c.note ?? contactUsage(c);
    final short = c.address.length > 26
        ? '${c.address.substring(0, 14)}…${c.address.substring(c.address.length - 8)}'
        : c.address;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: c.favorite ? 'Remove from favourites' : 'Add to favourites',
              onPressed: onFavorite,
              icon: Icon(
                c.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                color: c.favorite ? s.warning : s.fgDim,
              ),
            ),
            Expanded(
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: zuniaSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: s.fg,
                            ),
                          ),
                        ),
                        if (network != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: s.line),
                            ),
                            child: Text(
                              network.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: zuniaMono(fontSize: 9, color: s.fgDim),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      short,
                      style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(
                          fontSize: 12,
                          color: c.isValid ? s.fgMuted : s.dangerFg,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!pickMode)
              IconButton(
                tooltip: 'Copy address',
                onPressed: () {
                  ClipboardGuard.copy(c.address);
                  ZuniaHaptics.selection();
                },
                icon: Icon(Icons.copy_rounded, size: 18, color: s.fgMuted),
              )
            else if (ZuniaPlatform.isCupertino(context))
              Icon(Icons.chevron_right, size: 18, color: s.fgFaint),
          ],
        ),
      ),
    );
  }
}

/// Create or edit one contact; delete after a confirmation. The address is
/// checked as it is typed: checksum first, then the prefix of the network the
/// contact is pinned to, the same rules [addContact] applies on save.
class ContactSheet extends ConsumerStatefulWidget {
  const ContactSheet({super.key, this.contact, this.initialAddress, this.initialChainId});

  /// Null creates a new contact.
  final AddressBookEntry? contact;

  /// Prefill for "Save this recipient" from a send that just went through.
  final String? initialAddress;
  final String? initialChainId;

  @override
  ConsumerState<ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends ConsumerState<ContactSheet> {
  late final _label = TextEditingController(text: widget.contact?.label ?? '');
  late final _address = TextEditingController(
    text: widget.contact?.address ?? widget.initialAddress ?? '',
  );
  late final _note = TextEditingController(text: widget.contact?.note ?? '');
  late String? _chainId = widget.contact?.chainId ?? widget.initialChainId;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _address.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickNetwork() async {
    final chains = ChainCatalog.isLoaded
        ? ChainCatalog.instance.sorted([
            for (final a in ref.read(chainAccountsProvider)) a.chain,
          ])
        : const <ChainEntry>[];
    final picked = await pickNetwork(
      context,
      chains: chains,
      selected: _chainId ?? allNetworks,
      title: 'Network for this contact',
      allowAll: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _chainId = picked == allNetworks ? null : picked;
      _error = null;
    });
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScannerScreen(
          title: 'Scan an address',
          extractAddress: true,
        ),
      ),
    );
    if (!mounted || raw == null) return;
    setState(() => _address.text = extractBech32Address(raw) ?? raw);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() => _address.text = extractBech32Address(text) ?? text);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final book = ref.read(addressBookProvider.notifier);
    try {
      final contact = widget.contact;
      if (contact == null) {
        await book.add(
          ContactDraft(
            label: _label.text,
            address: _address.text,
            chainId: _chainId,
            note: _note.text,
          ),
        );
      } else {
        await book.update(
          contact.id,
          ContactPatch(
            label: _label.text,
            address: _address.text,
            chainId: _chainId,
            clearChainId: _chainId == null,
            note: _note.text,
            clearNote: _note.text.trim().isEmpty,
          ),
        );
      }
      unawaited(ZuniaHaptics.success());
      if (mounted) Navigator.of(context).pop();
    } on AddressBookError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final contact = widget.contact;
    if (contact == null) return;
    final ok = await showZuniaConfirm(
      context,
      title: 'Delete ${contact.label}?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(addressBookProvider.notifier).remove(contact.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final chain = _chainId == null
        ? null
        : (ChainCatalog.isLoaded ? ChainCatalog.instance.find(_chainId!) : null);
    final typed = _address.text.trim();
    final problem = typed.isEmpty
        ? null
        : contactAddressProblem(typed, _chainId, catalogPrefix);
    final canSave = _label.text.trim().isNotEmpty &&
        typed.isNotEmpty &&
        problem == null &&
        !_busy;
    final prefix = chain?.bech32Prefix ?? 'cosmos';

    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZuniaInput(
            controller: _label,
            label: 'NAME',
            hint: 'Treasury',
            autofocus: widget.contact == null && widget.initialAddress != null,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          ZuniaInput(
            controller: _address,
            label: 'ADDRESS',
            hint: '${prefix}1…',
            errorText: problem,
            onChanged: (_) => setState(() => _error = null),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Paste',
                  visualDensity: VisualDensity.compact,
                  onPressed: _paste,
                  icon: Icon(Icons.content_paste_rounded, size: 18, color: s.fgMuted),
                ),
                IconButton(
                  tooltip: 'Scan QR code',
                  visualDensity: VisualDensity.compact,
                  onPressed: _scan,
                  icon: Icon(Icons.qr_code_scanner, size: 18, color: s.fgMuted),
                ),
              ],
            ),
          ),
          if (typed.isNotEmpty && problem == null) ...[
            const SizedBox(height: 4),
            Text(
              chain == null
                  ? 'Valid address. Offered on every network using '
                      '${bech32PrefixOf(typed)}1… addresses.'
                  : 'Valid on ${chain.chainName}.',
              style: zuniaSans(fontSize: 12, color: s.success),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'NETWORK',
            style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgMuted),
          ),
          const SizedBox(height: 8),
          Semantics(
            button: true,
            label: 'Network: ${chain?.chainName ?? 'any network'}. Change',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _pickNetwork,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: s.line),
                ),
                child: Row(
                  children: [
                    if (chain != null)
                      ChainAvatar(chain: chain, size: 26)
                    else
                      Icon(Icons.public, size: 22, color: s.fgMuted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Text(
                          chain?.chainName ?? 'Any network with this prefix',
                          style: zuniaSans(fontSize: 14, color: s.fg),
                        ),
                      ),
                    ),
                    Icon(Icons.expand_more, color: s.fgMuted),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ZuniaInput(
            controller: _note,
            label: 'NOTE (OPTIONAL)',
            hint: 'Cold storage, memo required…',
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ZuniaCallout(tone: ZuniaCalloutTone.danger, body: _error!),
          ],
          const SizedBox(height: 18),
          ZuniaButton(
            label: widget.contact == null ? 'Save contact' : 'Save changes',
            size: ZuniaButtonSize.lg,
            loading: _busy,
            onPressed: canSave ? _save : null,
          ),
          if (widget.contact != null) ...[
            const SizedBox(height: 10),
            ZuniaButton(
              label: 'Delete contact',
              variant: ZuniaButtonVariant.danger,
              size: ZuniaButtonSize.lg,
              onPressed: _busy ? null : _delete,
            ),
          ],
        ],
      ),
    );
  }
}
