import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// WASD / arrows → tri-state axes, exactly like `framework/input.ts` and
/// `godot-gd-app/scripts/kb.gd`.
///
/// Deliberately global (`HardwareKeyboard.instance.addHandler`) rather than a
/// `Focus`/`KeyboardListener` widget: the controls panel steals focus the
/// moment anyone touches a slider, and a playground that stops responding to
/// WASD after you move a slider is worthless. The handler always returns
/// `false`, so real text fields keep working.
///
/// Held state is a set fed by key events; edge state ("pressed this frame") is
/// cleared by [endFrame]. Scripted runs set [autopilot] and drive [autoX] /
/// [autoY], so a lab never learns whether a human or a script is playing.
class Kb {
  const Kb._();

  static final Set<LogicalKeyboardKey> _held = <LogicalKeyboardKey>{};
  static final Set<LogicalKeyboardKey> _edge = <LogicalKeyboardKey>{};

  /// Feed the axes from [autoX] / [autoY] instead of the keyboard.
  static bool autopilot = false;

  /// Scripted horizontal axis, used when [autopilot] is set.
  static double autoX = 0.0;

  /// Scripted vertical axis, used when [autopilot] is set.
  static double autoY = 0.0;

  /// Pointer position in window coords — run it through `WorldView.wx`/`wy`
  /// to aim in world space.
  static Offset mousePos = Offset.zero;

  static bool _mouseDown = false;
  static bool _installed = false;
  static AppLifecycleListener? _lifecycle;

  /// Attach the global handler. Safe to call more than once.
  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_onKey);
    // A window that loses focus mid-stride never delivers the key-up, so the
    // player would keep sprinting into a wall after alt-tabbing back.
    _lifecycle = AppLifecycleListener(onInactive: clear);
  }

  /// Detach the global handler (tests, hot restart).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    HardwareKeyboard.instance.removeHandler(_onKey);
    _lifecycle?.dispose();
    _lifecycle = null;
    clear();
  }

  static bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      _held.add(e.logicalKey);
      _edge.add(e.logicalKey);
    } else if (e is KeyUpEvent) {
      _held.remove(e.logicalKey);
    }
    return false; // never swallow — text fields and shortcuts still work
  }

  /// Forget every held/edge key.
  static void clear() {
    _held.clear();
    _edge.clear();
    _mouseDown = false;
  }

  /// Is [k] held right now?
  static bool down(LogicalKeyboardKey k) => _held.contains(k);

  /// Did [k] go down during this frame? Cleared by [endFrame].
  static bool pressed(LogicalKeyboardKey k) => _edge.contains(k);

  /// Left button pressed this frame (edge). Fed by the shell's gesture layer.
  static bool get mouseDown => _mouseDown;

  /// Record a primary-button press for this frame.
  static void feedMouseDown() => _mouseDown = true;

  /// Drop the per-frame edge state. Call once, at the end of the frame.
  static void endFrame() {
    _edge.clear();
    _mouseDown = false;
  }

  /// −1 / 0 / +1. Both directions held cancels, like the wire encoding.
  static double moveX() {
    if (autopilot) return autoX;
    final l = down(LogicalKeyboardKey.keyA) ||
        down(LogicalKeyboardKey.arrowLeft);
    final r = down(LogicalKeyboardKey.keyD) ||
        down(LogicalKeyboardKey.arrowRight);
    if (r == l) return 0.0;
    return r ? 1.0 : -1.0;
  }

  /// −1 / 0 / +1, screen-down positive (world y grows downward).
  static double moveY() {
    if (autopilot) return autoY;
    final u = down(LogicalKeyboardKey.keyW) || down(LogicalKeyboardKey.arrowUp);
    final d = down(LogicalKeyboardKey.keyS) ||
        down(LogicalKeyboardKey.arrowDown);
    if (d == u) return 0.0;
    return d ? 1.0 : -1.0;
  }

  /// Any movement intent this frame.
  static bool anyMove() => moveX() != 0.0 || moveY() != 0.0;
}
