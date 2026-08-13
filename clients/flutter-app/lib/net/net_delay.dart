import 'package:colyseus/colyseus.dart';

/// A named latency setting.
typedef LatencyPreset = ({double delayMs, double jitterMs, String label});

/// Injected-latency control shared by every lab.
///
/// Localhost has no latency, so nothing these labs demonstrate is visible
/// without injecting some. The SDK does it at the transport seam, which is
/// the honest place — everything above it, including reconciliation, behaves
/// exactly as it would on a real connection.
class NetDelay {
  NetDelay._();

  /// The presets the lab UI cycles through.
  static const presets = <LatencyPreset>[
    (delayMs: 0, jitterMs: 0, label: 'off'),
    (delayMs: 80, jitterMs: 10, label: '80 ms + 10 jitter'),
    (delayMs: 200, jitterMs: 0, label: '200 ms'),
    (delayMs: 200, jitterMs: 80, label: '200 ms + 80 jitter'),
    (delayMs: 400, jitterMs: 60, label: '400 ms + 60 jitter'),
  ];

  static int _index = 0;
  static final Set<ColyseusRoom> _rooms = {};

  /// The preset in effect.
  static LatencyPreset get current => presets[_index];

  /// Index of the preset in effect.
  static int get index => _index;

  /// Applies preset [i] to every registered room.
  static void select(int i) {
    _index = i.clamp(0, presets.length - 1);
    _apply();
  }

  /// Moves to the next preset, wrapping.
  static void cycle() => select((_index + 1) % presets.length);

  /// Registers [room] so it follows the current preset.
  ///
  /// Call it after joining, and again after a reconnect — the wrap is bound to
  /// a transport, and reconnecting installs a new one.
  static void register(ColyseusRoom room) {
    _rooms.add(room);
    _applyTo(room);
  }

  /// Stops tracking [room].
  static void unregister(ColyseusRoom room) {
    _rooms.remove(room);
  }

  /// Drops every registered room's connection, to exercise reconnection.
  static void dropAll() {
    for (final room in _rooms) {
      room.dropConnection();
    }
  }

  /// Packets the injector is currently holding.
  static int get inFlight => Colyseus.packetsInFlight;

  static void _apply() {
    for (final room in _rooms) {
      _applyTo(room);
    }
  }

  static void _applyTo(ColyseusRoom room) {
    room.setLatency(
      delayMs: current.delayMs,
      jitterMs: current.jitterMs,
    );
  }
}
