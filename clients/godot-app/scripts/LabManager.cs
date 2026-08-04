using System;
using System.Threading.Tasks;
using Colyseus;
using Godot;
// Inside a Node2D subclass the bare name `Draw` is the inherited CanvasItem.Draw
// event; labs are plain classes and don't need this.
using PDraw = Playground.Draw;

namespace Playground
{
    /// <summary>
    /// The shell: one scene, one Node2D. _Process() drives the active lab's
    /// netcode, _Draw() paints the arena and the panel. Port of client/main.ts
    /// minus the web-only chrome (sidebar, docs panel, deep links).
    /// </summary>
    public partial class LabManager : Node2D
    {
        private readonly App _app = new App();
        private ILab[] _labs;
        private int _labIndex;
        private ILab _active;
        private bool _switching;
        private string _error;
        private double _lastNow;

        // --smoke: headless boot check — mount every lab in turn, count patches
        // (type-erased, via the clock stamp), verify the decode thread on the
        // first, exit 0/1. The acceptance harness grows out of this.
        private bool _smoke;
        private double _smokeDeadline, _smokeStamp;
        private int _smokeTarget, _smokePatches;
        private int _mainThread, _decodeThread;

        public string Endpoint =
            System.Environment.GetEnvironmentVariable("PLAYGROUND_ENDPOINT") ?? "ws://localhost:5173";

        public override void _Ready()
        {
            _mainThread = System.Environment.CurrentManagedThreadId;
            _smoke = Array.IndexOf(OS.GetCmdlineUserArgs(), "--smoke") >= 0;
            if (_smoke) _smokeDeadline = RoomClock.GetNow() + 10000;

            if (Sim.SelfCheck() != 0) GD.PushError("shared-sim port mismatch");

            _app.Client = new Client(Endpoint);
            _labs = new ILab[] { new Lab00(), new Lab01(), new Lab02(), new Lab03(),
                new Lab04(), new Lab05(), new Lab06(), new Lab07(), new Lab08(),
                new Lab09(), new Lab10(), new Lab11() };
            _ = SwitchTo(0);
        }

        private async Task SwitchTo(int index)
        {
            if (_switching) return;
            _switching = true;
            _error = null;
            try
            {
                if (_active != null)
                {
                    _active.Unmount();
                    if (_active.Room != null) await _active.Room.Leave(true);
                    _active = null;
                }
                _labIndex = index;
                var lab = _labs[index];
                if (await lab.Mount(_app))
                {
                    lab.BindReconnect();
                    _active = lab;
                    if (_smoke && index == 0) WireSmoke(lab);
                }
                else _error = $"state never arrived for {lab.Id}";
            }
            catch (Exception e) { _error = e.Message; }
            finally { _switching = false; }
        }

        public override void _UnhandledInput(InputEvent e)
        {
            if (e is InputEventKey k) Kb.Feed(k);
            else if (e is InputEventMouseButton m) Kb.FeedMouse(m);
        }

        public override void _Process(double delta)
        {
            // Deliver due packets first: the injector queues both directions and
            // only drains here, on the main thread.
            NetDelay.PumpAll();

            Kb.MousePos = GetViewport().GetMousePosition();

            double now = RoomClock.GetNow();
            double dt = _lastNow > 0 ? now - _lastNow : 0;
            _lastNow = now;

            // Guard on the lab NUMBER, not the index: the labs are ordered 00..11,
            // digits map 0-9 to labs 00-09, matching the other shells.
            for (int i = 0; i < _labs.Length; i++)
            {
                int n = _labs[i].Num;
                if (n < 10 && Kb.Key(Key.Key0 + n)) _ = SwitchTo(i);
            }
            // The digits only reach labs 0-9; [ ] are the only way to a 2-digit lab.
            if (Kb.Key(Key.Bracketleft)) _ = SwitchTo((_labIndex + _labs.Length - 1) % _labs.Length);
            if (Kb.Key(Key.Bracketright)) _ = SwitchTo((_labIndex + 1) % _labs.Length);
            if (Kb.Key(Key.L)) NetDelay.NextPreset();
            if (Kb.Key(Key.D)) NetDelay.DropAll();
            if (Kb.Key(Key.P)) { _app.PrivateRoom = !_app.PrivateRoom; _ = SwitchTo(_labIndex); }

            _active?.Frame(_app, now, dt);

            if (_smoke) SmokeStep(now);

            Kb.EndFrame();
            QueueRedraw();
        }

        public override void _Draw()
        {
            PDraw.C = this;
            var size = GetViewportRect().Size;
            float w = size.X, h = size.Y;
            const float panelW = 300, pad = 18;
            PDraw.Rect(new Rect2(0, 0, w, h), Palette.Bg);
            PDraw.Rect(new Rect2(w - panelW - pad * 2, 44, panelW + pad * 2, h - 44 - 46), Palette.Panel);

            _app.Stage = new Rect2(0, 44, w - panelW - pad * 2, h - 44 - 46);
            _app.View.Fit(_app.Stage);
            _app.Hud.Begin(w - panelW - pad, 60, panelW);
            if (_active == null || !_active.OwnArena) PDraw.Arena(_app.View);

            if (_active != null) _active.Render(_app);
            else PDraw.Text(_app.Stage.Position.X, _app.Stage.Position.Y + _app.Stage.Size.Y / 2,
                _app.Stage.Size.X, _error ?? "connecting...",
                _error != null ? Palette.Bad : Palette.TextDim, 12, HorizontalAlignment.Center);

            TopBar(w);
            BottomBar(w, h);
        }

        private void TopBar(float w)
        {
            PDraw.Rect(new Rect2(0, 0, w, 44), Palette.Panel);
            PDraw.Text(16, 6, 300, "PREDICTION PLAYGROUND", Palette.Accent, 12);
            PDraw.Text(16, 22, 300, "godot  (C#)", Palette.TextFaint, 10);

            var lab = _labs[_labIndex];
            PDraw.Text(210, 6, 700, $"{lab.Num:00}  {lab.Title}", Palette.Text, 13);
            PDraw.Text(210, 22, 700, lab.Blurb, Palette.TextDim, 10);
        }

        private void BottomBar(float w, float h)
        {
            float y = h - 46;
            PDraw.Rect(new Rect2(0, y, w, 46), Palette.Panel);
            var clock = _active?.Clock;
            string line = clock != null
                ? $"RTT {clock.SmoothedRtt():F0} ms    JITTER {clock.Jitter():F0} ms    " +
                  $"INJECTED {NetDelay.PresetLabel}    IN FLIGHT {NetDelay.InFlight()} pkt    " +
                  $"ROOM {(_app.PrivateRoom ? "private" : "shared")}"
                : $"INJECTED {NetDelay.PresetLabel}    connecting...";
            PDraw.Text(16, y + 14, w - 32, line, Palette.Text, 11);
            PDraw.Text(w - 460, y + 14, 444, "0-9 lab   [ ] prev/next   L latency   D drop   P private",
                Palette.TextFaint, 10, HorizontalAlignment.Right);
        }

        // ------------------------------------------------------------- smoke

        private void WireSmoke(ILab lab)
        {
            var room = lab.RoomOf<PredictProbe.LabSchema.MoveState>();
            if (room == null) return;
            room.OnStateChange += (state, isFirst) =>
                _decodeThread = System.Environment.CurrentManagedThreadId;
        }

        private void SmokeStep(double now)
        {
            if (now > _smokeDeadline)
            {
                GD.Print($"SMOKE FAIL timeout at lab {_smokeTarget}: " +
                         $"error={_error ?? "none"} patches={_smokePatches}");
                GetTree().Quit(1);
                _smoke = false;
                return;
            }
            if (_active == null || _labIndex != _smokeTarget || _switching) return;

            double stamp = _active.Clock?.LastServerTime() ?? 0;
            if (stamp > 0 && stamp != _smokeStamp)
            {
                if (_smokeStamp > 0) _smokePatches++;   // first read is history, not an arrival
                _smokeStamp = stamp;
            }
            if (_smokePatches < 3) return;

            GD.Print($"SMOKE lab {_active.Id} OK ({_smokePatches} patches)");
            _smokeTarget++;
            _smokePatches = 0;
            _smokeStamp = 0;
            if (_smokeTarget >= _labs.Length)
            {
                bool threadOk = _decodeThread == 0 || _decodeThread == _mainThread;
                GD.Print(threadOk
                    ? $"SMOKE OK all {_labs.Length} labs (decode thread {_decodeThread} == main)"
                    : $"SMOKE FAIL decode thread {_decodeThread} != main {_mainThread}");
                GetTree().Quit(threadOk ? 0 : 1);
                _smoke = false;
                return;
            }
            _smokeDeadline = now + 10000;
            _ = SwitchTo(_smokeTarget);
        }
    }
}
