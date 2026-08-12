import 'package:colyseus_flutter/colyseus_flutter.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'controls.dart';
import 'draw_kit.dart';
import 'hud.dart';
import 'kb.dart';
import 'lab.dart';
import 'labs/lab00_split.dart';
import 'labs/lab01_feel_the_lag.dart';
import 'labs/lab02_clocks.dart';
import 'labs/lab03_reconcile.dart';
import 'labs/lab04_interp_modes.dart';
import 'labs/lab05_dead_reckoning.dart';
import 'labs/lab06_lag_comp.dart';
import 'labs/lab07_wysiwyg.dart';
import 'labs/lab08_optimistic_events.dart';
import 'labs/lab09_predicted_spawns.dart';
import 'labs/lab10_composite_sim.dart';
import 'labs/lab11_deterministic_rng.dart';
import 'net/net_delay.dart';
import 'palette.dart';
import 'world_view.dart';

/// Where the playground server is. Vite serves the client and the Colyseus
/// server from one port, and it must be started with `--host 0.0.0.0` or it
/// binds IPv6 loopback only and native clients cannot reach it.
const defaultEndpoint = 'ws://127.0.0.1:5173';

/// Width of the right-hand panel.
const _panelWidth = 336.0;

/// The app shell: one connection, one frame loop, one lab at a time.
class PlaygroundShell extends StatefulWidget {
  const PlaygroundShell({super.key, this.endpoint = defaultEndpoint});

  final String endpoint;

  @override
  State<PlaygroundShell> createState() => _PlaygroundShellState();
}

class _PlaygroundShellState extends State<PlaygroundShell>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final ColyseusClient _client;
  late final LabContext _ctx;

  final _frame = _FrameSignal();
  final _view = WorldView();

  final List<Lab> _labs = [
    Lab00Split(),
    Lab01FeelTheLag(),
    Lab02Clocks(),
    Lab03Reconcile(),
    Lab04InterpModes(),
    Lab05DeadReckoning(),
    Lab06LagComp(),
    Lab07Wysiwyg(),
    Lab08OptimisticEvents(),
    Lab09PredictedSpawns(),
    Lab10CompositeSim(),
    Lab11DeterministicRng(),
  ];

  Lab? _active;
  String _status = 'connecting…';
  bool _switching = false;
  double _lastNow = 0;
  double _controlsHeight = 0;
  int _controlsRevision = 0;

  @override
  void initState() {
    super.initState();

    Kb.install();

    // The app owns the frame, so the SDK's own poll timer is turned off and
    // pumping happens once per tick instead — decode, prediction and rendering
    // then all see the same state within a frame.
    Colyseus.autoPoll = false;

    _client = ColyseusClient(widget.endpoint);
    _ctx = LabContext(client: _client, view: _view);

    _ticker = createTicker(_onTick)..start();
    // Land on reconcile: it shows the whole idea in one screen.
    _switchTo(_labs.firstWhere((lab) => lab.id == '03'));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _active?.unmount();
    _closeRoom(_active);
    _client.dispose();
    Kb.uninstall();
    Colyseus.autoPoll = true;
    super.dispose();
  }

  void _onTick(Duration _) {
    // Release inbound traffic and deliver events before anything reads state.
    Colyseus.pump();

    _hotkeys();

    final lab = _active;
    if (lab != null && lab.room != null) {
      final now = lab.room!.clock.now;
      final dt = _lastNow > 0 ? now - _lastNow : 0.0;
      _lastNow = now;
      lab.frame(_ctx, now, dt);
    }

    Kb.endFrame();
    _frame.tick();
  }

  void _hotkeys() {
    for (var i = 0; i < _labs.length && i < _digitKeys.length; i++) {
      if (Kb.pressed(_digitKeys[i])) _switchTo(_labs[i]);
    }

    // There are more labs than digit keys, so brackets step through the whole
    // list the way the other ports do.
    if (Kb.pressed(LogicalKeyboardKey.bracketLeft)) _step(-1);
    if (Kb.pressed(LogicalKeyboardKey.bracketRight)) _step(1);
    if (Kb.pressed(LogicalKeyboardKey.keyL)) {
      NetDelay.cycle();
      _bumpControls();
    }
    if (Kb.pressed(LogicalKeyboardKey.keyK)) NetDelay.dropAll();
  }

  /// One digit per lab, in list order — not by lab id, since the ids skip.
  static const _digitKeys = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  /// Moves [delta] labs along the list, wrapping.
  void _step(int delta) {
    final current = _active;
    if (current == null) return;
    final i = _labs.indexOf(current);
    if (i < 0) return;
    _switchTo(_labs[(i + delta + _labs.length) % _labs.length]);
  }

  Future<void> _switchTo(Lab lab) async {
    if (_switching || identical(lab, _active)) return;
    _switching = true;

    final previous = _active;
    setState(() {
      _active = null;
      _status = 'joining ${lab.title}…';
    });

    if (previous != null) {
      previous.unmount();
      await _closeRoom(previous);
    }

    try {
      final ok = await lab.mount(_ctx);
      if (!mounted) return;
      if (!ok) {
        setState(() => _status =
            'could not join ${lab.title} — is the playground server running?');
        _switching = false;
        return;
      }

      lab.room?.onReconnect.listen((_) => lab.onReconnect());
      _lastNow = 0;
      setState(() {
        _active = lab;
        _status = '';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'join failed: $e');
    } finally {
      _switching = false;
    }
  }

  Future<void> _closeRoom(Lab? lab) async {
    final room = lab?.room;
    if (room == null) return;

    // Give the socket a moment to close before the room is freed; tearing it
    // down underneath the live transport is what the SDK's own tests avoid.
    room.setLatency();
    await room.leave();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    Colyseus.pump();
    room.dispose();
    lab!.room = null;
  }

  void _bumpControls() => setState(() => _controlsRevision++);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.bg,
      body: Stack(
        children: [
          // Aiming labs read the pointer through Kb, the same way they read
          // the keyboard. The control panel sits above this in the stack, so
          // it keeps its own clicks.
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerHover: (e) => Kb.mousePos = e.localPosition,
              onPointerMove: (e) => Kb.mousePos = e.localPosition,
              onPointerDown: (e) {
                Kb.mousePos = e.localPosition;
                if (e.buttons & kPrimaryButton != 0) Kb.feedMouseDown();
              },
              child: CustomPaint(
                painter: _ShellPainter(
                  repaint: _frame,
                  labOf: () => _active,
                  ctx: _ctx,
                  view: _view,
                  controlsHeight: () => _controlsHeight,
                  panelWidth: _panelWidth,
                  status: () => _status,
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            width: _panelWidth,
            child: _panel(),
          ),
        ],
      ),
    );
  }

  Widget _panel() {
    final lab = _active;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _labPicker(),
            const SizedBox(height: 8),
            ControlsPanel(
              key: ValueKey('${lab?.id}-$_controlsRevision'),
              // Every knob rebuilds the panel after it fires, so a control
              // that changes lab state shows its new value immediately
              // instead of when the lab is next mounted.
              specs: [
                ...?lab?.controls(_ctx).map((s) => s.withRefresh(_bumpControls)),
                ..._networkControls(),
              ],
              onHeight: (h) => _controlsHeight = h,
            ),
          ],
        ),
      ),
    );
  }

  Widget _labPicker() {
    return DropdownButtonFormField<String>(
      initialValue: _active?.id,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Lab',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final lab in _labs)
          DropdownMenuItem(
            value: lab.id,
            child: Text('${lab.id} · ${lab.title}',
                overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (id) {
        final lab = _labs.firstWhere((l) => l.id == id);
        _switchTo(lab);
      },
    );
  }

  List<ControlSpec> _networkControls() {
    return [
      const NoteSpec('— network —'),
      RadioSpec<int>(
        'injected latency',
        [
          for (var i = 0; i < NetDelay.presets.length; i++)
            (value: i, label: NetDelay.presets[i].label),
        ],
        NetDelay.index,
        (i) {
          NetDelay.select(i);
          _bumpControls();
        },
      ),
      ButtonsSpec([
        (label: 'Drop connection', onPressed: NetDelay.dropAll),
      ]),
      const NoteSpec('Keys: 1-9 labs · [ ] step · L latency · K drop'),
    ];
  }
}

/// Repaint signal — ticked once per frame so the painter runs without any
/// widget rebuild.
class _FrameSignal extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _ShellPainter extends CustomPainter {
  _ShellPainter({
    required Listenable repaint,
    required this.labOf,
    required this.ctx,
    required this.view,
    required this.controlsHeight,
    required this.panelWidth,
    required this.status,
  }) : super(repaint: repaint);

  final Lab? Function() labOf;
  final LabContext ctx;
  final WorldView view;
  final double Function() controlsHeight;
  final double panelWidth;
  final String Function() status;

  @override
  void paint(Canvas canvas, Size size) {
    final stage = Rect.fromLTWH(0, 0, size.width - panelWidth, size.height);
    final draw = DrawKit(canvas, view);

    draw.rect(Rect.fromLTWH(0, 0, size.width, size.height), Palette.bg);
    draw.rect(
      Rect.fromLTWH(stage.width, 0, panelWidth, size.height),
      Palette.panel,
    );

    final lab = labOf();
    if (lab == null) {
      draw.text(24, stage.height / 2, stage.width - 48, status(),
          Palette.textDim, size: 14);
      return;
    }

    draw.text(20, 20, stage.width - 40, '${lab.id} · ${lab.title}',
        Palette.text, size: 16);
    draw.text(20, 42, stage.width - 40, lab.blurb, Palette.textDim, size: 12);

    view.fit(Rect.fromLTWH(
      stage.left,
      stage.top + 64,
      stage.width,
      stage.height - 88,
    ));

    ctx.draw = draw;
    ctx.hud = Hud(draw)
      ..begin(stage.width + 16, 96 + controlsHeight(), panelWidth - 32);

    if (!lab.ownArena) draw.arena();
    lab.render(ctx);
  }

  @override
  bool shouldRepaint(covariant _ShellPainter oldDelegate) => true;
}
