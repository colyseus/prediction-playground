import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'palette.dart';

/// One row of the lab's control panel.
///
/// Declarative on purpose: a lab describes the knobs it wants and owns the
/// values; [ControlsPanel] renders them. That keeps the labs free of widget
/// code, mirroring the web build's `ControlsPanel` and the Godot port's
/// keyboard-only stand-in.
sealed class ControlSpec {
  const ControlSpec();

  /// A copy whose callback also runs [after].
  ///
  /// A lab's control mutates lab state, and the panel is a widget that only
  /// rebuilds when told to — so without this the knob keeps showing the value
  /// it had when the panel was last built. The shell chains a rebuild onto
  /// every spec here rather than asking each lab to remember.
  ControlSpec withRefresh(VoidCallback after);
}

/// A continuous knob — smoothing, latency, delay.
final class SliderSpec extends ControlSpec {
  const SliderSpec(
    this.label,
    this.min,
    this.max,
    this.value,
    this.onChanged, {
    this.divisions,
    this.format,
  });

  /// Row caption.
  final String label;

  /// Inclusive range.
  final double min;
  final double max;

  /// Current value, owned by the lab.
  final double value;

  /// Called live while dragging.
  final ValueChanged<double> onChanged;

  /// Snap the track into N steps; null is continuous.
  final int? divisions;

  /// Value readout; defaults to one decimal.
  final String Function(double value)? format;

  @override
  SliderSpec withRefresh(VoidCallback after) => SliderSpec(
        label,
        min,
        max,
        value,
        (v) {
          onChanged(v);
          after();
        },
        divisions: divisions,
        format: format,
      );
}

/// An on/off knob.
final class ToggleSpec extends ControlSpec {
  const ToggleSpec(this.label, this.value, this.onChanged);

  /// Row caption.
  final String label;

  /// Current value, owned by the lab.
  final bool value;

  /// Called on flip.
  final ValueChanged<bool> onChanged;

  @override
  ToggleSpec withRefresh(VoidCallback after) => ToggleSpec(label, value, (v) {
        onChanged(v);
        after();
      });
}

/// A one-of-N picker, rendered as a segmented button (the web build's
/// segmented picker — interpolation modes, bot patterns).
final class RadioSpec<T> extends ControlSpec {
  const RadioSpec(this.label, this.options, this.value, this.onChanged);

  /// Row caption.
  final String label;

  /// The choices, in display order.
  final List<({String label, T value})> options;

  /// Current selection, owned by the lab.
  final T value;

  /// Called on pick.
  final ValueChanged<T> onChanged;

  @override
  RadioSpec<T> withRefresh(VoidCallback after) =>
      RadioSpec<T>(label, options, value, (v) {
        onChanged(v);
        after();
      });

  /// Builds the picker itself.
  ///
  /// This lives on the spec because `T` has to stay bound. A `case
  /// RadioSpec():` pattern binds the type argument as `dynamic`, and a
  /// `void Function(int)` is not a `void Function(dynamic)` — reading
  /// [onChanged] through that view throws before the widget ever appears.
  Widget buildPicker() {
    return SegmentedButton<T>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 11),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      segments: [
        for (final o in options)
          ButtonSegment<T>(value: o.value, label: Text(o.label)),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// A row of momentary actions — impulse, teleport, drop transport.
final class ButtonsSpec extends ControlSpec {
  const ButtonsSpec(this.buttons);

  /// The actions, in display order.
  final List<({String label, VoidCallback onPressed})> buttons;

  @override
  ButtonsSpec withRefresh(VoidCallback after) => ButtonsSpec([
        for (final b in buttons)
          (
            label: b.label,
            onPressed: () {
              b.onPressed();
              after();
            }
          ),
      ]);
}

/// A line of explanatory text between knobs.
final class NoteSpec extends ControlSpec {
  const NoteSpec(this.text);

  /// The caption.
  final String text;

  @override
  NoteSpec withRefresh(VoidCallback after) => this;
}

/// The panel that renders a lab's [ControlSpec] list.
///
/// Reports its laid-out height through [onHeight] so the painted HUD can start
/// directly beneath it — the panel is Material widgets, the HUD is canvas, and
/// only the widget half knows how tall it ended up.
class ControlsPanel extends StatelessWidget {
  const ControlsPanel({
    super.key,
    required this.specs,
    this.onHeight,
    this.title,
  });

  /// The knobs to render, top to bottom.
  final List<ControlSpec> specs;

  /// Called (post-frame) whenever the rendered height changes.
  final ValueChanged<double>? onHeight;

  /// Optional heading.
  final String? title;

  @override
  Widget build(BuildContext context) {
    return _MeasureHeight(
      onHeight: onHeight,
      child: Theme(
        data: _panelTheme,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Palette.panel.fade(0.94),
            border: Border.all(color: Palette.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) _caption(title!, Palette.textFaint, 10),
                for (final spec in specs) _row(spec),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ControlSpec spec) {
    switch (spec) {
      case SliderSpec():
        final fmt = spec.format ?? ((double v) => v.toStringAsFixed(1));
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _caption(spec.label, Palette.textDim, 11),
                  _caption(fmt(spec.value), Palette.accent, 11),
                ],
              ),
              SizedBox(
                height: 24,
                child: SliderTheme(
                  // Null colours resolve from the panel ColorScheme.
                  data: const SliderThemeData(
                    trackHeight: 3,
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: spec.value.clamp(spec.min, spec.max),
                    min: spec.min,
                    max: spec.max,
                    divisions: spec.divisions,
                    onChanged: spec.onChanged,
                  ),
                ),
              ),
            ],
          ),
        );

      case ToggleSpec():
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: _caption(spec.label, Palette.textDim, 11)),
            Transform.scale(
              scale: 0.75,
              child: Switch(value: spec.value, onChanged: spec.onChanged),
            ),
          ],
        );

      case RadioSpec():
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _caption(spec.label, Palette.textDim, 11),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: spec.buildPicker(),
              ),
            ],
          ),
        );

      case ButtonsSpec():
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final b in spec.buttons)
                FilledButton.tonal(
                  onPressed: b.onPressed,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                  child: Text(b.label),
                ),
            ],
          ),
        );

      case NoteSpec():
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _caption(spec.text, Palette.textFaint, 10),
        );
    }
  }

  // `SegmentedButton` needs the element type; a helper keeps the generic bound
  // without leaking it into the switch above.
  static Widget _caption(String s, Color color, double size) => Text(
        s,
        style: TextStyle(color: color, fontSize: size, height: 1.3),
      );

  static final ThemeData _panelTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: Palette.accent,
      onPrimary: Palette.bg,
      secondary: Palette.blue,
      surface: Palette.panel,
      onSurface: Palette.text,
      surfaceContainerHighest: Palette.inset,
      outline: Palette.border,
    ),
  );
}

/// Reports its child's laid-out height once per change.
class _MeasureHeight extends SingleChildRenderObjectWidget {
  const _MeasureHeight({required this.onHeight, required Widget super.child});

  final ValueChanged<double>? onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMeasureHeight).onHeight = onHeight;
  }
}

class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onHeight);

  ValueChanged<double>? onHeight;
  double _reported = -1;

  @override
  void performLayout() {
    super.performLayout();
    if (size.height == _reported) return;
    _reported = size.height;
    // Deferred: the callback almost always triggers a repaint, which is
    // illegal to schedule from inside layout.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      onHeight?.call(_reported);
    });
  }
}
