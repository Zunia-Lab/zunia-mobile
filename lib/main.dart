import 'package:flutter/material.dart';
import 'package:zunia_mobile/theme/zunia_theme.dart';
import 'package:zunia_mobile/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZuniaApp());
}

class ZuniaApp extends StatelessWidget {
  const ZuniaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zunia',
      debugShowCheckedModeBanner: false,
      theme: ZuniaTheme.light,
      darkTheme: ZuniaTheme.dark,
      themeMode: ThemeMode.dark,
      home: const HomeScreen(),
    );
  }
}
