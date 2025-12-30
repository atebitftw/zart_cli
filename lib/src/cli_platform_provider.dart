import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_console/dart_console.dart';
import 'package:zart/zart.dart';
import 'package:zart_cli/src/cli_configuration_manager.dart'
    show cliConfigManager;
import 'package:zart_cli/src/cli_renderer.dart';
import 'package:zart_cli/src/cli_settings_screen.dart' show CliSettingsScreen;

/// CLI/Terminal implementation of [PlatformProvider].
///
/// Provides terminal-based rendering and input for running Z-machine and
/// Glulx games in a command-line environment.
///
/// This implementation delegates to:
/// - [CliRenderer] for rendering RenderFrames
/// - Terminal input for keyboard/mouse handling
class CliPlatformProvider extends PlatformProvider {
  final Console _console = Console();
  late final CliRenderer _renderer;

  /// Renderer for emitting [RenderFrame]s.
  CliRenderer get renderer => _renderer;
  late PlatformCapabilities _capabilities;

  /// Whether a quick action is in progress.
  bool _isQuickSave = false;
  bool _isQuickRestore = false;

  /// Callback for scroll notifications.
  late final void Function(int delta)? scrollCallback;

  @override
  void setScrollCallback(void Function(int delta)? callback) {
    scrollCallback = callback;
  }

  /// Create a CLI platform provider.
  CliPlatformProvider({required String gameName}) : _gameName = gameName {
    _renderer = CliRenderer(this);
  }

  final String _gameName;

  @override
  String get gameName => _gameName;

  @override
  void onInit(GameFileType fileType) {
    _renderer.isGameRunning = true; // Enable user's text color for game text
    cliConfigManager.load();
    _updateCapabilities();
  }

  void _updateCapabilities() {
    _capabilities = PlatformCapabilities(
      screenHeight: _renderer.screenHeight,
      screenWidth: _renderer.screenWidth,
      supportsColors: true,
      supportsTrueColor: true,
      supportsBold: true,
      supportsItalic: true,
      supportsFixedPitch: true,
      supportsUnicode: true,
      supportsGraphics: false,
      supportsSound: false,
      supportsMouse: false,
      supportsTimedInput: false,
      zartBarVisible: cliConfigManager.zartBarVisible,
    );
  }

  // ============================================================
  // CAPABILITIES
  // ============================================================

  @override
  PlatformCapabilities get capabilities {
    _updateCapabilities();
    return _capabilities;
  }

  // ============================================================
  // RENDERING
  // ============================================================

  @override
  void render(ScreenFrame frame) {
    _renderer.renderScreen(frame);
  }

  @override
  void enterDisplayMode() {
    _renderer.enterFullScreen();
  }

  @override
  void exitDisplayMode() {
    _renderer.exitFullScreen();
  }

  @override
  void showTempMessage(String message, {int seconds = 3}) {
    _renderer.showTempMessage(message, seconds: seconds);
  }

  @override
  Future<void> openSettings({bool isGameStarted = false}) async {
    await CliSettingsScreen().show(
      isGameStarted: isGameStarted,
      onRerender: () => _renderer.rerender(),
    );
  }

  // ============================================================
  // INPUT
  // ============================================================

  @override
  Future<InputEvent> readInput({int? timeout}) async {
    stdout.write('\x1B[?25h'); // Show cursor
    final key = _console.readKey();
    stdout.write('\x1B[?25l'); // Hide cursor

    // Handle control characters
    if (key.controlChar == ControlCharacter.ctrlC) {
      exitDisplayMode();
      exit(0);
    }

    // Map control characters to input events
    final ctrlName = key.controlChar != ControlCharacter.none
        ? key.controlChar.toString().split('.').last
        : null;

    // Check for macros first (except for Ctrl+C which is handled above)
    if (ctrlName != null && ctrlName.startsWith('ctrl')) {
      final match = RegExp(
        r'ctrl([a-z])$',
        caseSensitive: false,
      ).matchAsPrefix(ctrlName);
      if (match != null) {
        final letter = match.group(1)!.toLowerCase();
        final bindingKey = 'ctrl+$letter';
        final cmd = cliConfigManager.getBinding(bindingKey);
        if (cmd != null) {
          return InputEvent.macro(cmd);
        }
      }
    }

    switch (key.controlChar) {
      case ControlCharacter.enter:
        return const InputEvent.character('\n', specialKey: SpecialKey.enter);
      case ControlCharacter.backspace:
        return const InputEvent.character(
          '\x7F',
          specialKey: SpecialKey.delete,
        );
      case ControlCharacter.arrowUp:
        return const InputEvent.specialKey(SpecialKey.arrowUp);
      case ControlCharacter.arrowDown:
        return const InputEvent.specialKey(SpecialKey.arrowDown);
      case ControlCharacter.arrowLeft:
        return const InputEvent.specialKey(SpecialKey.arrowLeft);
      case ControlCharacter.arrowRight:
        return const InputEvent.specialKey(SpecialKey.arrowRight);
      case ControlCharacter.F1:
        await openSettings(isGameStarted: true);
        return const InputEvent.none();
      case ControlCharacter.F2:
        _isQuickSave = true;
        return InputEvent.macro('save');
      case ControlCharacter.F3:
        _isQuickRestore = true;
        return InputEvent.macro('restore');
      case ControlCharacter.F4:
        _renderer.cycleTextColor();
        return const InputEvent.none();
      case ControlCharacter.pageUp:
        scrollCallback?.call(5);
        return const InputEvent.none();
      case ControlCharacter.pageDown:
        scrollCallback?.call(-5);
        return const InputEvent.none();
      case ControlCharacter.escape:
        return const InputEvent.specialKey(SpecialKey.escape);
      default:
        if (key.char.isNotEmpty) {
          return InputEvent.character(key.char);
        }
        return const InputEvent.none();
    }
  }

  /// Reads a line of text input from the terminal.
  ///
  /// Calls [readInput] repeatedly until the Enter key is pressed,
  /// accumulating characters and handling backspace. Returns the
  /// entered string (without the trailing newline).
  Future<String> readLine() async {
    final buffer = StringBuffer();
    while (true) {
      final event = await readInput();
      if (event.specialKey == SpecialKey.enter) {
        stdout.writeln();
        return buffer.toString();
      } else if (event.specialKey == SpecialKey.delete) {
        // Handle backspace
        if (buffer.isNotEmpty) {
          final str = buffer.toString();
          buffer.clear();
          buffer.write(str.substring(0, str.length - 1));
          stdout.write('\b \b'); // Erase character on screen
        }
      } else if (event.character != null && event.character!.isNotEmpty) {
        buffer.write(event.character);
        stdout.write(event.character);
      }
    }
  }

  @override
  ({
    Future<void> onKeyPressed,
    bool Function() wasPressed,
    void Function() cleanup,
  })
  setupAsyncKeyWait() {
    var pressed = false;
    final completer = Completer<void>();

    // Start blocking key wait in a separate isolate
    // This allows animations to continue in the main isolate
    unawaited(
      Isolate.run(() {
        // Read a single byte from stdin (blocking)
        stdin.readByteSync();
        return true;
      }).then((_) {
        pressed = true;
        if (!completer.isCompleted) {
          completer.complete();
        }
      }),
    );

    return (
      onKeyPressed: completer.future,
      wasPressed: () => pressed,
      cleanup: () {
        // The isolate completes on its own when key is pressed
        // If we exit early, the isolate will still be waiting but that's OK
      },
    );
  }

  // ============================================================
  // FILE IO
  // ============================================================

  @override
  Future<String?> saveGame(List<int> data, {String? suggestedName}) async {
    String filename;
    if (_isQuickSave) {
      _isQuickSave = false;
      // Extract basename and remove extension
      String base = gameName.split(RegExp(r'[/\\]')).last;
      if (base.contains('.')) {
        base = base.substring(0, base.lastIndexOf('.'));
      }
      filename = 'quick_save_$base.sav';
    } else {
      // Manual/Interactive save
      stdout.write('\nEnter filename to save: ');
      filename = await readLine();
    }

    if (filename.isEmpty) return null;

    if (!filename.toLowerCase().endsWith('.sav')) {
      filename += '.sav';
    }

    try {
      final f = File(filename);
      f.writeAsBytesSync(data);
      return filename;
    } catch (e) {
      onError('Save failed: $e');
      return null;
    }
  }

  @override
  Future<List<int>?> restoreGame({String? suggestedName}) async {
    String filename;
    if (_isQuickRestore) {
      _isQuickRestore = false;
      // Extract basename and remove extension
      String base = gameName.split(RegExp(r'[/\\]')).last;
      if (base.contains('.')) {
        base = base.substring(0, base.lastIndexOf('.'));
      }
      filename = 'quick_save_$base.sav';
    } else {
      // Manual/Interactive restore
      stdout.write('\nEnter filename to restore: ');
      filename = await readLine();
    }

    if (filename.isEmpty) return null;

    if (!filename.toLowerCase().endsWith('.sav')) {
      filename += '.sav';
    }

    try {
      final f = File(filename);
      if (!f.existsSync()) {
        onError('File not found: "$filename"');
        return null;
      }
      return f.readAsBytesSync();
    } catch (e) {
      onError('Restore failed: $e');
      return null;
    }
  }

  // ============================================================
  // LIFECYCLE
  // ============================================================

  @override
  void onQuit() {
    _renderer.isGameRunning = false;
    // Nothing special to do
  }

  @override
  void onError(String message) {
    stderr.writeln('Zart Error: $message');
  }

  @override
  void dispose() {
    // Nothing special to clean up
  }
}
