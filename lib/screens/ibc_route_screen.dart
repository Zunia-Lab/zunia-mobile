import 'dart:async';

import 'package:bech32/bech32.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/screens/transfer_sent_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/widgets/address_field_actions.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Recipient + route preview after the amount step.
///
/// Same-prefix sends stay on one chain. Cross-send / different bech32 prefix
/// uses IBC: discover open channels, let the user pick or type one, and check
/// it on the source LCD.
class IbcRouteScreen extends ConsumerStatefulWidget {
  const IbcRouteScreen({
    super.key,
    required this.chainId,
    required this.denom,
    required this.amount,
    required this.fromAddress,
    required this.sourcePrefix,
    this.destChainId,
    this.destPrefix,
    this.forceIbc = false,
  });

  final String chainId;
  final String denom;
  final String amount;
  final String fromAddress;
  final String sourcePrefix;
  final String? destChainId;
  final String? destPrefix;
  final bool forceIbc;

  @override
  ConsumerState<IbcRouteScreen> createState() => _IbcRouteScreenState();
}

class _IbcRouteScreenState extends ConsumerState<IbcRouteScreen> {
  final _recipient = TextEditingController();
  final _channel = TextEditingController();
  List<IbcChannelOption> _channels = const [];
  bool _loadingChannels = false;
  IbcChannelCheck? _check;
  Timer? _validateTimer;

  @override
  void initState() {
    super.initState();
    if (widget.forceIbc && widget.destChainId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _discover());
    }
  }

  @override
  void dispose() {
    _validateTimer?.cancel();
    _recipient.dispose();
    _channel.dispose();
    super.dispose();
  }

  String? get _destPrefix {
    if (widget.destPrefix != null) return widget.destPrefix;
    final value = _recipient.text.trim();
    if (value.isEmpty) return null;
    try {
      return const Bech32Codec().decode(value).hrp;
    } catch (_) {
      return null;
    }
  }

  String? get _error {
    final value = _recipient.text.trim();
    if (value.isEmpty) return null;
    try {
      const Bech32Codec().decode(value);
    } catch (_) {
      return 'Not a valid bech32 address';
    }
    final expected = widget.destPrefix ??
        (widget.forceIbc ? null : widget.sourcePrefix);
    if (expected != null && _destPrefix != expected) {
      return 'Expected a $expected… address';
    }
    return null;
  }

  bool get _ibc {
    if (widget.forceIbc) return true;
    final dest = _destPrefix;
    return dest != null && dest != widget.sourcePrefix;
  }

  Future<void> _discover() async {
    final destId = widget.destChainId;
    final source = ChainCatalog.instance.find(widget.chainId);
    if (destId == null || source == null) return;
    setState(() => _loadingChannels = true);
    final rows =
        await ref.read(chainClientProvider).findIbcChannels(source, destId);
    if (!mounted) return;
    setState(() {
      _channels = rows;
      _loadingChannels = false;
      if (rows.length == 1) {
        _channel.text = rows.first.channelId;
        _check = IbcChannelCheck(
          ok: true,
          state: IbcChannelState.open,
          channelId: rows.first.channelId,
          message: 'Open · ${rows.first.counterpartyChainId ?? destId}',
          counterpartyChannelId: rows.first.counterpartyChannelId,
          counterpartyChainId: rows.first.counterpartyChainId,
        );
      }
    });
  }

  void _onChannelChanged(String value) {
    setState(() {});
    _validateTimer?.cancel();
    final normalized = ChainClient.normalizeChannelId(value);
    final known = _channels.where((c) => c.channelId == normalized).firstOrNull;
    if (known != null) {
      setState(() {
        _check = IbcChannelCheck(
          ok: true,
          state: IbcChannelState.open,
          channelId: known.channelId,
          message: 'Open · ${known.counterpartyChainId ?? widget.destChainId}',
          counterpartyChannelId: known.counterpartyChannelId,
          counterpartyChainId: known.counterpartyChainId,
        );
      });
      return;
    }
    if (normalized.isEmpty) {
      setState(() => _check = null);
      return;
    }
    _validateTimer = Timer(const Duration(milliseconds: 400), () async {
      final source = ChainCatalog.instance.find(widget.chainId);
      if (source == null) return;
      final result = await ref.read(chainClientProvider).validateIbcChannel(
            source,
            normalized,
            destChainId: widget.destChainId,
          );
      if (!mounted) return;
      setState(() => _check = result);
    });
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScannerScreen(
          title: 'Scan address',
          extractAddress: true,
        ),
      ),
    );
    if (!mounted || raw == null) return;
    final address = extractBech32Address(raw) ?? raw;
    setState(() => _recipient.text = address);
  }

  Future<void> _pickBook() async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AddressBookScreen(
          pickMode: true,
          prefixFilter: widget.destPrefix ??
              (widget.forceIbc ? null : widget.sourcePrefix),
        ),
      ),
    );
    if (!mounted || address == null) return;
    setState(() => _recipient.text = address);
  }

  void _review() {
    final s = ZuniaSemanticsExt.of(context);
    final dest = _destPrefix ?? widget.sourcePrefix;
    final channel = ChainClient.normalizeChannelId(_channel.text);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          gradient: s.sheetGradient,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: s.line)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
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
                'Confirm transfer',
                style: zuniaSans(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.3,
                  color: s.fg,
                ),
              ),
              const SizedBox(height: 18),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: s.surfaceRaisedGradient,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 20,
                  ),
                  child: Column(
                    children: [
                      Text(
                        'SENDING',
                        style: zuniaMono(
                          fontSize: 10,
                          letterSpacing: 1.6,
                          color: s.fgMuted,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          ZuniaAmount(value: widget.amount, hero: true),
                          const SizedBox(width: 8),
                          Text(
                            widget.denom,
                            style: zuniaMono(fontSize: 16, color: s.fgMuted),
                          ),
                        ],
                      ),
                      if (_ibc) ...[
                        const SizedBox(height: 8),
                        Text(
                          'via $channel',
                          style: zuniaMono(fontSize: 11, color: s.fgDim),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ZuniaKeyValueRow(
                label: 'To',
                value: truncateAddress(_recipient.text.trim()),
              ),
              const SizedBox(height: 10),
              ZuniaKeyValueRow(
                label: 'Message',
                value: _ibc ? 'MsgTransfer' : 'MsgSend',
              ),
              const SizedBox(height: 10),
              ZuniaKeyValueRow(
                label: 'Route',
                value: _ibc
                    ? '${widget.sourcePrefix} → $dest · $channel'
                    : 'same chain · ${widget.chainId}',
              ),
              const SizedBox(height: 16),
              const ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: 'Decoded on device',
                body:
                    'Decoded from the raw message. Nothing hidden behind a hash.',
              ),
              const SizedBox(height: 16),
              ZuniaButton(
                label: 'Hold to sign',
                size: ZuniaButtonSize.lg,
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => TransferSentScreen(
                        title: 'Transfer sent',
                        summary:
                            '${widget.amount} ${widget.denom} to ${truncateAddress(_recipient.text.trim())}.',
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final contacts = ref.watch(addressBookProvider);
    final dest = _destPrefix;
    final channelOk = !_ibc || (_check?.ok ?? false);
    final ready = _error == null &&
        _recipient.text.trim().isNotEmpty &&
        channelOk;
    final channelId = ChainClient.normalizeChannelId(_channel.text);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: widget.forceIbc ? 'Cross-send' : 'Recipient',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            '2 / 2',
            style: zuniaMono(fontSize: 11, color: s.fgDim),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      s.accent.withValues(alpha: 0.24),
                      s.accent.withValues(alpha: 0.1),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: s.info.withValues(alpha: 0.5)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
                  child: TextField(
                    controller: _recipient,
                    style: zuniaMono(fontSize: 12, height: 1.4, color: s.fg),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText:
                          '${widget.destPrefix ?? widget.sourcePrefix}1…',
                      hintStyle: zuniaMono(fontSize: 12, color: s.fgDim),
                      errorText: _error,
                      errorStyle: zuniaMono(fontSize: 10, color: s.danger),
                      suffixIcon: AddressFieldActions(
                        onScan: _scanQr,
                        onBook: _pickBook,
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 72,
                        minHeight: 36,
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              if (dest != null && _error == null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.info,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _ibc
                          ? 'Valid $dest address'
                          : 'Valid ${widget.chainId} address',
                      style: zuniaMono(fontSize: 10.5, color: s.info),
                    ),
                  ],
                ),
              ],
              if (_ibc) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const ZuniaSectionLabel('IBC channel'),
                    const Spacer(),
                    if (_loadingChannels)
                      Text(
                        'Finding…',
                        style: zuniaMono(fontSize: 10, color: s.fgDim),
                      )
                    else if (_channels.isNotEmpty)
                      Text(
                        '${_channels.length} open',
                        style: zuniaMono(fontSize: 10, color: s.fgDim),
                      ),
                  ],
                ),
                if (_channels.length > 1) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in _channels)
                        ChoiceChip(
                          label: Text(
                            option.channelId,
                            style: zuniaMono(fontSize: 11, color: s.fg),
                          ),
                          selected: _channel.text == option.channelId,
                          onSelected: (_) {
                            _channel.text = option.channelId;
                            _onChannelChanged(option.channelId);
                          },
                          selectedColor: s.stateSelected,
                          backgroundColor: s.glass,
                          side: BorderSide(color: s.line),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                ZuniaInput(
                  controller: _channel,
                  label: _channels.isEmpty ? 'Channel id' : 'Or type a channel',
                  hint: 'channel-141',
                  errorText: _check == null || _check!.ok
                      ? null
                      : _check!.message,
                  onChanged: _onChannelChanged,
                ),
                if (_check?.ok == true) ...[
                  const SizedBox(height: 8),
                  Text(
                    _check!.message,
                    style: zuniaMono(fontSize: 10.5, color: s.success),
                  ),
                ],
              ],
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: s.surfaceRaisedGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ZuniaSectionLabel('IBC route'),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _HopChip(
                              title: widget.denom,
                              subtitle: widget.chainId,
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    height: 1,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          s.lineStrong,
                                          s.info.withValues(alpha: 0.9),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: s.info,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: _HopChip(
                              title: _ibc ? (dest ?? '…') : widget.denom,
                              subtitle: _ibc
                                  ? (widget.destChainId ?? dest ?? '…')
                                  : widget.chainId,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      ZuniaKeyValueRow(
                        label: 'Amount',
                        value: '${widget.amount} ${widget.denom}',
                      ),
                      const SizedBox(height: 9),
                      ZuniaKeyValueRow(
                        label: 'From',
                        value: truncateAddress(widget.fromAddress),
                      ),
                      if (_ibc) ...[
                        const SizedBox(height: 9),
                        ZuniaKeyValueRow(
                          label: 'Channel',
                          value: channelId.isEmpty ? 'not selected' : channelId,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (contacts.isNotEmpty) ...[
                const SizedBox(height: 18),
                const ZuniaSectionLabel('Recent'),
                const SizedBox(height: 12),
                for (final contact in contacts.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => setState(
                          () => _recipient.text = contact.address,
                        ),
                        borderRadius: BorderRadius.circular(13),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: s.glass2),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 22,
                                  height: 22,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: s.glass2,
                                  ),
                                  child: Text(
                                    contact.label.isEmpty
                                        ? '?'
                                        : contact.label.characters.first
                                            .toUpperCase(),
                                    style: zuniaMono(
                                      fontSize: 9,
                                      color: s.fgMuted,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '${contact.label} · ${truncateAddress(contact.address)}',
                                    overflow: TextOverflow.ellipsis,
                                    style: zuniaMono(
                                      fontSize: 11,
                                      color: s.fgMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _pickBook,
                    child: Text(
                      'Address book',
                      style: zuniaMono(fontSize: 11, color: s.info),
                    ),
                  ),
                ),
              ],
            ],
          ),
          footer: ZuniaButton(
            label: 'Review transfer',
            size: ZuniaButtonSize.lg,
            onPressed: ready ? _review : null,
          ),
        ),
      ),
    );
  }
}

class _HopChip extends StatelessWidget {
  const _HopChip({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Column(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: s.glass2,
          ),
          child: Text(
            title.length > 4 ? title.substring(0, 4) : title,
            style: zuniaMono(fontSize: 8, color: s.fg),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: zuniaMono(fontSize: 9.5, height: 1.3, color: s.fgMuted),
        ),
      ],
    );
  }
}
