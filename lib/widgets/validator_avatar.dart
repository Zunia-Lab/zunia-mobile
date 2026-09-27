import 'package:flutter/material.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/validator_avatar_resolver.dart';
import 'package:zunia_mobile/services/validator_logo_cache.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Host-side cache around [ZuniaValidatorAvatar].
class CachedValidatorAvatar extends StatefulWidget {
  const CachedValidatorAvatar({
    super.key,
    required this.chainId,
    required this.operatorAddress,
    required this.moniker,
    this.chainName,
    this.identity = '',
    this.size = 28,
  });

  final String chainId;
  final String? chainName;
  final String operatorAddress;
  final String identity;
  final String moniker;
  final double size;

  @override
  State<CachedValidatorAvatar> createState() => _CachedValidatorAvatarState();
}

class _CachedValidatorAvatarState extends State<CachedValidatorAvatar> {
  late Future<String?> _cached;

  ValidatorLogoInput get _input => ValidatorLogoInput(
        chainId: widget.chainId,
        chainName: widget.chainName,
        operatorAddress: widget.operatorAddress,
        identity: widget.identity,
        logoSlugs: ChainCatalog.isLoaded
            ? ChainCatalog.instance.find(widget.chainId)?.logoSlugs
            : null,
      );

  Future<String?> _resolve() async {
    final stored = await ValidatorLogoCache.read(_input);
    if (stored != null && stored.isNotEmpty) return stored;
    final fromKeybase = await ValidatorAvatarResolver.resolveOne(widget.identity);
    if (fromKeybase != null && fromKeybase.isNotEmpty) {
      await ValidatorLogoCache.write(_input, fromKeybase);
      return fromKeybase;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _cached = _resolve();
  }

  @override
  void didUpdateWidget(covariant CachedValidatorAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chainId != widget.chainId ||
        oldWidget.chainName != widget.chainName ||
        oldWidget.operatorAddress != widget.operatorAddress ||
        oldWidget.identity != widget.identity) {
      _cached = _resolve();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _cached,
      builder: (context, snapshot) {
        return ZuniaValidatorAvatar(
          chainId: widget.chainId,
          chainName: widget.chainName,
          operatorAddress: widget.operatorAddress,
          identity: widget.identity,
          logoSlugs: _input.logoSlugs,
          moniker: widget.moniker,
          size: widget.size,
          cachedUrl: snapshot.data,
          onResolved: (url) => ValidatorLogoCache.write(_input, url),
          onCacheInvalid: () => ValidatorLogoCache.clear(
            widget.chainId,
            widget.operatorAddress,
          ),
        );
      },
    );
  }
}
