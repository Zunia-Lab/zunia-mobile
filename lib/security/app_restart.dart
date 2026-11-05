import 'package:flutter/widgets.dart';

/// Rebuilds everything below it from scratch: a new ProviderScope, so no
/// provider keeps data from the wallet that was just removed, and a new
/// navigator stack.
class AppRestart extends StatefulWidget {
  const AppRestart({super.key, required this.builder});

  /// Builds the app; give [key] to the ProviderScope.
  final Widget Function(Key key) builder;

  /// Restarts the app above [context]. A no-op where there is none (tests
  /// that pump a screen alone).
  static void restart(BuildContext context) {
    context.findAncestorStateOfType<_AppRestartState>()?._restart();
  }

  @override
  State<AppRestart> createState() => _AppRestartState();
}

class _AppRestartState extends State<AppRestart> {
  Key _key = UniqueKey();

  void _restart() => setState(() => _key = UniqueKey());

  @override
  Widget build(BuildContext context) => widget.builder(_key);
}
