import 'dart:async';
import 'dart:io';

import 'package:dart_console/dart_console.dart';
import 'package:zart_cli/src/cli_configuration_manager.dart';
import 'package:zart/zart.dart';
import 'package:zart_cli/src/cli_platform_provider.dart';

const _zartBarText =
    "(Zart) F1=Settings, F2=QuickSave, F3=QuickLoad, F4=Text Color, PgUp/PgDn=Scroll";

/// Unified CLI renderer for both Z-machine and Glulx games.
///
/// Renders a [RenderFrame] to the terminal using ANSI escape codes.
/// Implements [CapabilityProvider] so VMs can query terminal capabilities.
class CliRenderer {
  final Console _console = Console();

  final CliPlatformProvider cliPlatformProvider;

  /// Optional debug log callback.
  void Function(String)? onDebugLog;

  /// Callback for F1 key.
  Future<void> Function()? onOpenSettings;

  /// Callback for F2 key.
  void Function()? onQuickSave;

  /// Callback for F3 key.
  void Function()? onQuickLoad;

  /// Callback for F4 key.
  void Function()? onCycleTextColor;

  /// Screen dimensions.
  int _cols = 80;
  int _rows = 24;

  int get screenWidth => _cols;

  int get screenHeight => _rows;

  /// Whether the game is currently running (vs title screen).
  /// When true, the user's text color preference is applied to game text.
  bool isGameRunning = false;

  /// Temporary status message.
  String? _tempMessage;
  DateTime? _tempMessageExpiry;

  /// Detect terminal size and update screen dimensions.
  CliRenderer(this.cliPlatformProvider) {
    _detectTerminalSize();
  }

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

  /// Enter full-screen mode using alternate screen buffer.
  void enterFullScreen() {
    stdout.write('\x1B[?1049h'); // Alternate screen buffer
    stdout.write('\x1B[?25l'); // Hide cursor
    stdout.write('\x1B[2J'); // Clear screen
    _console.rawMode = true;
    _detectTerminalSize();
  }

  /// Exit full-screen mode and restore normal terminal.
  void exitFullScreen() {
    stdout.write('\x1B[?25h'); // Show cursor
    stdout.write('\x1B[?1049l'); // Exit alternate screen buffer
    _console.rawMode = false;
  }

  /// Show a temporary status message in the zart bar.
  void showTempMessage(String message, {int seconds = 3}) {
    _tempMessage = message;
    _tempMessageExpiry = DateTime.now().add(Duration(seconds: seconds));
  }

  /// Last composited ScreenFrame (for re-rendering).
  ScreenFrame? _lastScreenFrame;

  /// Render a pre-composited ScreenFrame to the terminal.
  ///
  /// This is the primary rendering method used by PlatformProvider.
  void renderScreen(ScreenFrame frame, {bool saveFrame = true}) {
    if (saveFrame) _lastScreenFrame = frame;
    _detectTerminalSize();

    final buf = StringBuffer();
    buf.write('\x1B[?25l'); // Hide cursor during render
    buf.write('\x1B[H'); // Home position

    // Render screen buffer to terminal
    for (var row = 0; row < frame.height; row++) {
      buf.write(_renderRow(frame.cells[row], row));
      if (row < frame.height - 1) buf.write('\n');
    }

    buf.write('\x1B[0m'); // Reset styles

    // Draw zart bar (unless frame requests it hidden)
    if (cliPlatformProvider.capabilities.zartBarVisible &&
        cliConfigManager.zartBarVisible &&
        !frame.hideStatusBar) {
      _drawZartBar(buf);
    }

    // Position cursor using frame's tracked position
    if (frame.cursorVisible && frame.cursorY >= 0 && frame.cursorX >= 0) {
      buf.write('\x1B[${frame.cursorY + 1};${frame.cursorX + 1}H');
      buf.write('\x1B[?25h'); // Show cursor
    }

    stdout.write(buf.toString());
  }

  /// Re-render last frame (for scroll updates).
  void rerender() {
    if (_lastScreenFrame != null) {
      renderScreen(_lastScreenFrame!);
    }
  }

  /// Cycle the default text color through available options.
  ///
  /// Colors cycle through 1-9 (default, black, red, green, yellow,
  /// blue, magenta, cyan, white), skipping black (2) to avoid invisible text.
  void cycleTextColor() {
    var next = (cliConfigManager.textColor % 9) + 1;
    if (next == 2) next = 3; // Skip black
    cliConfigManager.textColor = next;
    cliConfigManager.save();
    rerender();
  }

  String _renderRow(List<RenderCell> cells, int rowIndex) {
    final buf = StringBuffer();
    buf.write('\x1B[${rowIndex + 1};1H'); // Position cursor
    buf.write('\x1B[K'); // Clear line

    // Use -1 as sentinel so first cell always triggers style application
    int lastFg = -1;
    int lastBg = -1;
    bool lastBold = false;
    bool lastItalic = false;
    bool lastReverse = false;

    for (final cell in cells) {
      // Check if style changed
      if (cell.fgColor != lastFg ||
          cell.bgColor != lastBg ||
          cell.bold != lastBold ||
          cell.italic != lastItalic ||
          cell.reverse != lastReverse) {
        buf.write('\x1B[0m'); // Reset

        // Apply foreground color (use configured default if not specified)
        // Only apply user's text color preference when the game is running
        // and the cell is not reversed (to preserve status bar styling)
        if (cell.fgColor != null) {
          buf.write(_rgbToFgAnsi(cell.fgColor!));
        } else if (isGameRunning && !cell.reverse) {
          buf.write(_zColorToFgAnsi(cliConfigManager.textColor));
        } else {
          buf.write('\x1B[39m'); // Default foreground
        }

        // Apply background color
        if (cell.bgColor != null) {
          buf.write(_rgbToBgAnsi(cell.bgColor!));
        }

        // Apply styles
        if (cell.bold) buf.write('\x1B[1m');
        if (cell.italic) buf.write('\x1B[3m');
        if (cell.reverse) buf.write('\x1B[7m');

        lastFg = cell.fgColor ?? -1;
        lastBg = cell.bgColor ?? -1;
        lastBold = cell.bold;
        lastItalic = cell.italic;
        lastReverse = cell.reverse;
      }

      buf.write(cell.char);
    }

    buf.write('\x1B[0m'); // Reset at end of row
    return buf.toString();
  }

  /// Convert RGB color to ANSI 24-bit foreground escape code.
  String _rgbToFgAnsi(int rgb) {
    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;
    return '\x1B[38;2;$r;$g;${b}m';
  }

  /// Convert RGB color to ANSI 24-bit background escape code.
  String _rgbToBgAnsi(int rgb) {
    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;
    return '\x1B[48;2;$r;$g;${b}m';
  }

  void _drawZartBar(StringBuffer buf) {
    // Check for expired temp message
    if (_tempMessage != null &&
        _tempMessageExpiry != null &&
        DateTime.now().isAfter(_tempMessageExpiry!)) {
      _tempMessage = null;
    }

    final text = _tempMessage ?? _zartBarText;
    final paddedText = text.padRight(_cols);
    final finalText = paddedText.length > _cols
        ? paddedText.substring(0, _cols)
        : paddedText;

    final barRow = _rows; // Last row (1-indexed)
    buf.write('\x1B[$barRow;1H');
    buf.write(_zColorToFgAnsi(cliConfigManager.zartBarForeground));
    buf.write(_zColorToBgAnsi(cliConfigManager.zartBarBackground));
    buf.write(finalText);
    buf.write('\x1B[0m');
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
}
