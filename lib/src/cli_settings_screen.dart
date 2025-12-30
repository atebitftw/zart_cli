import 'dart:io';

import 'package:dart_console/dart_console.dart';
import 'package:zart_cli/src/cli_configuration_manager.dart';

/// A settings screen for the Zart CLI application.
///
/// This version uses dart_console directly for all UI rendering and input,
/// eliminating the dependency on ZartTerminal. It manages its own screen
/// state and renders using ANSI escape codes.
class CliSettingsScreen {
  /// The console instance for input/output.
  final Console _console = Console();

  /// Screen dimensions.
  int _cols = 80;
  int _rows = 24;

  /// Allowed keys for custom key bindings.
  static const _allowedKeys = [
    'q',
    'w',
    'e',
    'r',
    't',
    'y',
    'u',
    'i',
    'o',
    'p',
    'a',
    's',
    'd',
    'f',
    'g',
    'h',
    'j',
    'k',
    'l',
  ];

  /// Creates a new settings screen.
  CliSettingsScreen();

  /// Detects the terminal size and updates screen dimensions.
  void _detectTerminalSize() {
    try {
      _cols = _console.windowWidth;
      _rows = _console.windowHeight;
    } catch (_) {
      _cols = 80;
      _rows = 24;
    }
    if (_cols <= 0) _cols = 80;
    if (_rows <= 0) _rows = 24;
  }

  /// Clears the screen.
  void _clearScreen() {
    stdout.write('\x1B[2J'); // Clear screen
    stdout.write('\x1B[H'); // Move cursor to home
  }

  /// Sets foreground and background colors using Z-machine color codes.
  void _setColors(int fg, int bg) {
    stdout.write(_zColorToFgAnsi(fg));
    stdout.write(_zColorToBgAnsi(bg));
  }

  /// Resets colors to default.
  void _resetColors() {
    stdout.write('\x1B[0m');
  }

  /// Writes text at the current cursor position.
  void _write(String text) {
    stdout.write(text);
  }

  /// Convert Z-machine color code (1-12) to ANSI foreground.
  String _zColorToFgAnsi(int zColor) {
    switch (zColor) {
      case 1:
        return '\x1B[39m'; // Default
      case 2:
        return '\x1B[30m'; // Black
      case 3:
        return '\x1B[31m'; // Red
      case 4:
        return '\x1B[32m'; // Green
      case 5:
        return '\x1B[33m'; // Yellow
      case 6:
        return '\x1B[34m'; // Blue
      case 7:
        return '\x1B[35m'; // Magenta
      case 8:
        return '\x1B[36m'; // Cyan
      case 9:
        return '\x1B[97m'; // Bright White
      case 10:
        return '\x1B[90m'; // Dark Grey
      default:
        return '';
    }
  }

  /// Convert Z-machine color code (1-12) to ANSI background.
  String _zColorToBgAnsi(int zColor) {
    switch (zColor) {
      case 1:
        return '\x1B[49m'; // Default
      case 2:
        return '\x1B[49m'; // Black (use default)
      case 3:
        return '\x1B[41m'; // Red
      case 4:
        return '\x1B[42m'; // Green
      case 5:
        return '\x1B[43m'; // Yellow
      case 6:
        return '\x1B[44m'; // Blue
      case 7:
        return '\x1B[45m'; // Magenta
      case 8:
        return '\x1B[46m'; // Cyan
      case 9:
        return '\x1B[47m'; // White
      case 10:
        return '\x1B[100m'; // Dark Grey
      default:
        return '';
    }
  }

  /// Reads a single character from the terminal.
  Future<String> _readChar() async {
    stdout.write('\x1B[?25h'); // Show cursor
    final key = _console.readKey();
    stdout.write('\x1B[?25l'); // Hide cursor

    if (key.controlChar == ControlCharacter.ctrlC) {
      stdout.write('\x1B[?25h'); // Show cursor
      stdout.write('\x1B[?1049l'); // Exit alternate screen buffer
      _console.rawMode = false;
      exit(0);
    }

    // Map control characters to their expected values
    if (key.controlChar == ControlCharacter.F1) return 'r';
    if (key.controlChar == ControlCharacter.enter) return '\n';
    if (key.controlChar == ControlCharacter.backspace) return '\x7F';
    if (key.controlChar == ControlCharacter.escape) return '\x1B';

    return key.char.isNotEmpty ? key.char : '';
  }

  /// Reads a line of input from the terminal.
  Future<String> _readLine() async {
    stdout.write('\x1B[?25h'); // Show cursor
    final buf = StringBuffer();

    while (true) {
      final key = _console.readKey();

      if (key.controlChar == ControlCharacter.enter) {
        stdout.write('\n');
        break;
      } else if (key.controlChar == ControlCharacter.backspace) {
        if (buf.length > 0) {
          final str = buf.toString();
          buf.clear();
          buf.write(str.substring(0, str.length - 1));
          stdout.write('\b \b');
        }
      } else if (key.controlChar == ControlCharacter.ctrlC) {
        stdout.write('\x1B[?25h'); // Show cursor
        stdout.write('\x1B[?1049l'); // Exit alternate screen buffer
        _console.rawMode = false;
        exit(0);
      } else if (key.controlChar == ControlCharacter.escape) {
        // Cancel input on Escape
        stdout.write('\n');
        return '';
      } else if (key.char.isNotEmpty &&
          key.controlChar == ControlCharacter.none) {
        buf.write(key.char);
        stdout.write(key.char);
      }
    }

    stdout.write('\x1B[?25l'); // Hide cursor
    return buf.toString();
  }

  /// Shows the settings screen.
  ///
  /// The [isGameStarted] parameter controls whether the menu shows
  /// "Resume Game" or "Start Game".
  ///
  /// The [onRerender] callback is called when returning to the game
  /// to refresh the game display.
  Future<void> show({
    bool isGameStarted = false,
    void Function()? onRerender,
  }) async {
    _detectTerminalSize();

    // We're already in alternate screen buffer from the game,
    // so we just need to render our UI over it

    try {
      while (true) {
        _renderSettingsScreen(isGameStarted);

        final input = await _readChar();
        final lowerChar = input.toLowerCase();

        if (lowerChar == 'r') {
          break; // Exit loop
        } else if (lowerChar == 'a') {
          await _addBinding();
        } else if (lowerChar == 'd') {
          await _deleteBinding();
        } else if (lowerChar == 'v') {
          cliConfigManager.zartBarVisible = !cliConfigManager.zartBarVisible;
        } else if (lowerChar == 'f') {
          // Cycle foreground 2-10
          var c = cliConfigManager.zartBarForeground + 1;
          if (c > 10) c = 2;
          cliConfigManager.zartBarForeground = c;
        } else if (lowerChar == 'b') {
          // Cycle background 2-10
          var c = cliConfigManager.zartBarBackground + 1;
          if (c > 10) c = 2;
          cliConfigManager.zartBarBackground = c;
        } else if (input == '\x1B') {
          // Escape key - exit settings
          break;
        }
      }

      // Trigger a rerender of the game screen when returning
      onRerender?.call();
    } catch (e) {
      // Ensure we don't leave the terminal in a bad state
      _resetColors();
    }
  }

  /// Renders the main settings screen.
  void _renderSettingsScreen(bool isGameStarted) {
    _clearScreen();
    stdout.write('\x1B[?25l'); // Hide cursor

    // Title
    _setColors(9, 6); // White on Blue
    _write('\n SETTINGS \n');
    _resetColors();

    // Navigation
    _write('[F1] or [R] To Return to Game\n');

    _write('\n');
    _write('-' * (_cols < 50 ? _cols : 50));
    _write('\n');

    // Zart Bar section
    _setColors(9, 6); // White on Blue
    _write('ZART BAR\n');
    _resetColors();

    _write(
      '[V] Visibility: ${cliConfigManager.zartBarVisible ? 'ON' : 'OFF'}\n',
    );
    _write('[F] Foreground Color\n');
    _write('[B] Background Color\n');

    // Preview
    _setColors(
      cliConfigManager.zartBarForeground,
      cliConfigManager.zartBarBackground,
    );
    _write(' [ ZART BAR STYLE PREVIEW ] ');
    _resetColors();

    _write('\n\n');
    _write('-' * (_cols < 50 ? _cols : 50));
    _write('\n');

    // Key bindings section
    _setColors(9, 6); // White on Blue
    _write('CUSTOM KEY BINDINGS (Ctrl+Key)\n');
    _resetColors();

    _write('Allowed Keys: ${_allowedKeys.join(', ')}\n\n');
    _write('[A] Add Binding\n');
    _write('[D] Delete Binding\n\n');

    final bindings = cliConfigManager.bindings;
    if (bindings.isEmpty) {
      _write('No macros defined.\n');
    } else {
      bindings.forEach((key, val) {
        _write('$key -> "$val"\n');
      });
    }
  }

  Future<void> _addBinding() async {
    _write('\n\nEnter letter `x` for Ctrl+x: ');

    final charKey = await _readChar();

    if (charKey.isEmpty || charKey.length > 1) {
      _write('\nInvalid input.\n');
      await _wait(1);
      return;
    }

    final lowerKey = charKey.toLowerCase();
    if (!_allowedKeys.contains(lowerKey)) {
      _write('\nKey "$lowerKey" is not allowed for binding.\n');
      _write('Allowed: ${_allowedKeys.join(',')}\n');
      await _wait(2);
      return;
    }

    final keyName = 'ctrl+$lowerKey';

    _write('\nEnter command for $keyName: ');
    final cmd = await _readLine();

    if (cmd.isNotEmpty) {
      cliConfigManager.setBinding(keyName, cmd);
      _write('\nBound $keyName to "$cmd".\n');
    } else {
      _write('\nCancelled.\n');
    }
    await _wait(1);
  }

  Future<void> _deleteBinding() async {
    _write('\n\nEnter letter `x` to delete Ctrl+x binding: ');

    final charKey = await _readChar();
    final keyName = 'ctrl+${charKey.toLowerCase()}';

    if (cliConfigManager.getBinding(keyName) != null) {
      cliConfigManager.setBinding(keyName, null);
      _write('\nDeleted binding for $keyName.\n');
    } else {
      _write('\nNo binding found for $keyName.\n');
    }
    await _wait(1);
  }

  Future<void> _wait(int seconds) {
    return Future.delayed(Duration(seconds: seconds));
  }
}
