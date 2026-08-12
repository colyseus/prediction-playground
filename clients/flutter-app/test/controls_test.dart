// The controls panel, exercised as widgets.
//
// Everything else in this suite drives labs headlessly and never builds the
// panel, so a control that throws when tapped looked green right up until
// someone used it.
import 'package:colyseus_playground/controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpPanel(WidgetTester tester, List<ControlSpec> specs) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 400, child: ControlsPanel(specs: specs)),
    ),
  ));
}

void main() {
  testWidgets('a slider reports its new value', (tester) async {
    var seen = -1.0;
    await pumpPanel(tester, [
      SliderSpec('smoothing', 0, 40, 20, (v) => seen = v),
    ]);

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(seen, isNot(-1.0), reason: 'the slider never reported');
  });

  testWidgets('a toggle reports its new value', (tester) async {
    bool? seen;
    await pumpPanel(tester, [
      ToggleSpec('server ghost', false, (v) => seen = v),
    ]);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(seen, isTrue);
  });

  testWidgets('a button fires', (tester) async {
    var fired = 0;
    await pumpPanel(tester, [
      ButtonsSpec([(label: 'Impulse', onPressed: () => fired++)]),
    ]);

    await tester.tap(find.text('Impulse'));
    await tester.pumpAndSettle();
    expect(fired, 1);
  });

  // A generic spec matched by a bare pattern binds its type argument as
  // dynamic, and a `void Function(int)` is not a `void Function(dynamic)` —
  // so an int-valued radio used to throw the moment the panel built it.
  testWidgets('an int radio builds and reports', (tester) async {
    var seen = -1;
    await pumpPanel(tester, [
      RadioSpec<int>(
        'injected latency',
        const [(label: 'off', value: 0), (label: '200 ms', value: 2)],
        0,
        (v) => seen = v,
      ),
    ]);

    expect(tester.takeException(), isNull,
        reason: 'building an int radio threw');

    await tester.tap(find.text('200 ms'));
    await tester.pumpAndSettle();
    expect(seen, 2);
  });

  testWidgets('a string radio builds and reports', (tester) async {
    var seen = '';
    await pumpPanel(tester, [
      RadioSpec<String>(
        'pattern',
        const [
          (label: 'patrol', value: 'patrol'),
          (label: 'wander', value: 'wander'),
        ],
        'patrol',
        (v) => seen = v,
      ),
    ]);

    expect(tester.takeException(), isNull,
        reason: 'building a string radio threw');

    await tester.tap(find.text('wander'));
    await tester.pumpAndSettle();
    expect(seen, 'wander');
  });

  testWidgets('a note renders', (tester) async {
    await pumpPanel(tester, [const NoteSpec('hold a movement key')]);
    expect(find.textContaining('hold a movement key'), findsOneWidget);
  });

  testWidgets('the panel renders every spec type together', (tester) async {
    await pumpPanel(tester, [
      const NoteSpec('mixed'),
      SliderSpec('smoothing', 0, 40, 20, (_) {}),
      ToggleSpec('ghost', true, (_) {}),
      RadioSpec<int>('latency', const [(label: 'off', value: 0)], 0, (_) {}),
      ButtonsSpec([(label: 'Drop', onPressed: () {})]),
    ]);
    expect(tester.takeException(), isNull);
  });

  // A lab's control mutates lab state, and the panel only rebuilds when told
  // to. Without the chained refresh the knob keeps showing its old value
  // until the lab is remounted, which looked like the selection being
  // ignored.
  group('withRefresh', () {
    testWidgets('a radio reflects the new selection immediately',
        (tester) async {
      var pattern = 'patrol';
      var rebuilds = 0;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                child: ControlsPanel(
                  specs: [
                    RadioSpec<String>(
                      'pattern',
                      const [
                        (label: 'patrol', value: 'patrol'),
                        (label: 'wander', value: 'wander'),
                      ],
                      pattern,
                      (v) => pattern = v,
                    ).withRefresh(() {
                      rebuilds++;
                      setState(() {});
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('wander'));
      await tester.pumpAndSettle();

      expect(pattern, 'wander');
      expect(rebuilds, 1, reason: 'the panel was never asked to rebuild');

      // The rendered selection, not just the backing value.
      final button = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(button.selected, {'wander'});
    });

    testWidgets('chains for every spec type', (tester) async {
      var refreshes = 0;
      void bump() => refreshes++;

      await pumpPanel(tester, [
        SliderSpec('a', 0, 10, 5, (_) {}).withRefresh(bump),
        ToggleSpec('b', false, (_) {}).withRefresh(bump),
        ButtonsSpec([(label: 'Go', onPressed: () {})]).withRefresh(bump),
        const NoteSpec('c').withRefresh(bump),
      ]);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(refreshes, greaterThanOrEqualTo(3),
          reason: 'a spec type did not chain its refresh');
    });
  });
}
