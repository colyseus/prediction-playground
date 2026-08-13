import 'package:colyseus/colyseus.dart';

import 'controls.dart';
import 'draw_kit.dart';
import 'hud.dart';
import 'world_view.dart';

/// Everything a lab needs from the shell.
class LabContext {
  /// The connected client.
  final ColyseusClient client;

  /// World-to-screen mapping for the arena, refreshed each frame.
  final WorldView view;

  /// The drawing surface for the current frame; only valid inside `render`.
  late DrawKit draw;

  /// The painted HUD for the current frame; only valid inside `render`.
  late Hud hud;

  LabContext({required this.client, required this.view});
}

/// One demonstration: a room, a per-frame update, and something to draw.
///
/// The shell owns the connection lifecycle and the frame loop; a lab supplies
/// what changes between them. [TState] types the lab's room — labs that join
/// with a `stateType:` read `room.state` through their generated class.
abstract class Lab<TState extends SchemaInstance> {
  /// Short id used in the lab picker.
  String get id;

  /// Display name.
  String get title;

  /// One line on what this lab shows.
  String get blurb;

  /// Whether the lab draws its own arena (split-screen labs do).
  bool get ownArena => false;

  /// The room this lab is connected to, once [mount] resolves.
  ColyseusRoom<TState>? room;

  /// Connects and sets up prediction. Returns false when the join failed.
  Future<bool> mount(LabContext ctx);

  /// Advances one frame: send inputs, read telemetry.
  ///
  /// [now] comes from the room clock, so it shares a timebase with prediction.
  void frame(LabContext ctx, double now, double dtMs) {}

  /// Draws the world and the HUD.
  void render(LabContext ctx) {}

  /// The controls this lab wants in the side panel.
  List<ControlSpec> controls(LabContext ctx) => const [];

  /// Releases everything the lab owns. The shell leaves the room itself.
  void unmount() {}

  /// Called after the SDK reconnects.
  ///
  /// The server counts input sequences from zero again and the decoder may
  /// have replaced instances, so anything holding one has to be rebuilt —
  /// reconcilers especially, or they replay inputs from the previous
  /// connection into the new one.
  void onReconnect() {}
}
