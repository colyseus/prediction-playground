import 'package:flutter/material.dart';

import 'palette.dart';
import 'shell.dart';
import 'sim/sim.dart';

/// Colyseus Prediction Playground — Flutter client.
///
/// Needs the playground server:
///   cd demos/prediction-tools && pnpm dev --host 0.0.0.0
///
/// Run with Impeller (still opt-in on macOS):
///   flutter run -d macos --enable-impeller
void main() {
  // The shared simulation has to match the server's operation for operation,
  // or reconciliation reports drift that isn't the network's fault. The
  // canaries pin that at startup.
  final failed = selfcheck();
  // ignore: avoid_print
  print('sim selfcheck: $failed failed');

  runApp(const PlaygroundApp());
}

class PlaygroundApp extends StatelessWidget {
  const PlaygroundApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Colyseus Prediction Playground',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Palette.accent,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Palette.bg,
      ),
      home: const PlaygroundShell(),
    );
  }
}
