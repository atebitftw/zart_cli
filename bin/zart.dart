import 'dart:io';

// import 'package:logging/logging.dart';
import 'package:zart/zart.dart' show GameRunner, GameRunnerException, debugger;
import 'package:zart_cli/src/cli_platform_provider.dart';

// final _logger = Logger.root;

// Zart CLI - A terminal-based player for Z-Machine and Inform games.
void main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln(_usage());
    exit(1);
  }

  final file = File(args.first);
  if (!file.existsSync()) {
    stdout.writeln(_usage());
    exit(1);
  }

  // This is the CLI implementation of the PlatformProvider API.
  // It handles all platform-specific IO operations (rendering, input, save/restore).
  final provider = CliPlatformProvider(gameName: args.first);

  // Instantiate the GameRunner with the CLI PlatformProvider.
  final runner = GameRunner(provider);

  // _logger.level = Level.INFO;
  // File debugFile = File("debug.log");
  // debugFile.writeAsStringSync("Debug Log: ${DateTime.now().toIso8601String()}\n");
  // debugFile.writeAsStringSync("Game: ${file.path}\n", mode: FileMode.append);
  // debugFile.writeAsStringSync("-------------------------\n\n", mode: FileMode.append);

  // _logger.onRecord.listen((record) {
  //   debugFile.writeAsStringSync("${record.message}\n", mode: FileMode.append);
  // });

  try {
    // Run the game.  GameRunner takes care of the rest.
    await runner.run(file.readAsBytesSync());
    runner.dispose();
    // debugger.flushLogs();
    exit(0);
  } on GameRunnerException catch (e) {
    debugger.flightRecorderEvent("GameRunnerException: ${e.message}");
    // debugger.flushLogs();
    exit(1);
  } catch (e, stack) {
    debugger.flightRecorderEvent("Error: $e\n$stack");
    // debugger.flushLogs();
    exit(1);
  }
}

String _usage() => '''
Zart CLI - Interactive Fiction Player for Z-Machine and Inform games.

Usage: zart <game_file>
''';
