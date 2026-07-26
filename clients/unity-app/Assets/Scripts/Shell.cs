using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using ColyseusSchema = Colyseus.Schema.Schema;
using UnityEngine;

namespace Playground
{
    /// <summary>Join helper — the shell owns joining so labs never do.</summary>
    public static class Shell
    {
        /// <summary>
        /// Multiple clients land in the SAME room by default (multiplayer is
        /// free); `P` forces a solo room, mirroring the web build's ?private=1.
        /// </summary>
        /// <param name="ready">
        /// What the caller needs decoded before it can wire up — the web build's
        /// `waitFor`. Waiting on `State` alone is NOT enough: the SDK instantiates
        /// it at join, but every collection field stays null until a patch fills
        /// it in, so a lab that reaches for `State.players` mounts on nothing.
        /// </param>
        public static async Task<Room<T>> JoinLab<T>(App app, string name, Func<Room<T>, bool> ready = null)
            where T : ColyseusSchema
        {
            var room = app.PrivateRoom
                ? await app.Client.Create<T>(name)
                : await app.Client.JoinOrCreate<T>(name);
            for (int i = 0; i < 200; i++)
            {
                if (room.State != null && (ready == null || ready(room))) break;
                await Task.Delay(25);
            }
            return room;
        }
    }

    /// <summary>
    /// The shell: one scene, one MonoBehaviour. Update() drives the active lab's
    /// netcode, OnGUI() draws the arena and the panel. Port of client/main.ts
    /// minus the web-only chrome (sidebar, docs panel, deep links).
    /// </summary>
    public class LabManager : MonoBehaviour
    {
        private readonly App _app = new App();
        private ILab[] _labs;
        private int _labIndex;
        private ILab _active;
        private bool _switching;
        private string _error;
        private double _lastNow;

        public string Endpoint = "ws://localhost:5173";

        private void Start()
        {
            Application.runInBackground = true;
            if (Sim.SelfCheck() != 0) Debug.LogError("shared-sim port mismatch");

            DelayedConnection.Install();
            _app.Client = new Client(Endpoint);
            _labs = new ILab[] { new Lab00(), new Lab01(), new Lab02(), new Lab03(), new Lab04(), new Lab05(), new Lab06(), new Lab07(), new Lab08(), new Lab09(), new Lab11() };
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
                if (await lab.Mount(_app)) _active = lab;
                else _error = $"state never arrived for {lab.Id}";
            }
            catch (Exception e) { _error = e.Message; }
            finally { _switching = false; }
        }

        private void Update()
        {
            // Deliver due packets first: the injector queues both directions and
            // only drains here, on the main thread.
            DelayedConnection.PumpAll();

            double now = RoomClock.GetNow();
            double dt = _lastNow > 0 ? now - _lastNow : 0;
            _lastNow = now;

            for (int i = 0; i < _labs.Length && i < 9; i++)
                if (Kb.Key(KeyCode.Alpha1 + _labs[i].Num - 1)) _ = SwitchTo(i);
            if (Kb.Key(KeyCode.L)) DelayedConnection.NextPreset();
            if (Kb.Key(KeyCode.D)) DelayedConnection.DropAll();
            if (Kb.Key(KeyCode.P)) { _app.PrivateRoom = !_app.PrivateRoom; _ = SwitchTo(_labIndex); }

            _active?.Frame(_app, now, dt);
        }

        private void OnGUI()
        {
            float w = Screen.width, h = Screen.height;
            const float panelW = 300, pad = 18;
            Draw.Rect(new Rect(0, 0, w, h), Palette.Bg);
            Draw.Rect(new Rect(w - panelW - pad * 2, 44, panelW + pad * 2, h - 44 - 46), Palette.Panel);

            _app.Stage = new Rect(0, 44, w - panelW - pad * 2, h - 44 - 46);
            _app.View.Fit(_app.Stage);
            _app.Hud.Begin(w - panelW - pad, 60, panelW);
            if (_active == null || !_active.OwnArena) Draw.Arena(_app.View);

            if (_active != null) _active.Render(_app);
            else
            {
                var style = new GUIStyle(GUI.skin.label)
                {
                    alignment = TextAnchor.MiddleCenter,
                    normal = { textColor = _error != null ? Palette.Bad : Palette.TextDim }
                };
                GUI.Label(_app.Stage, _error ?? "connecting...", style);
            }

            TopBar(w);
            BottomBar(w, h);
        }

        private void TopBar(float w)
        {
            Draw.Rect(new Rect(0, 0, w, 44), Palette.Panel);
            var s = new GUIStyle(GUI.skin.label) { fontSize = 12, normal = { textColor = Palette.Accent } };
            GUI.Label(new Rect(16, 6, 300, 16), "PREDICTION PLAYGROUND", s);
            s = new GUIStyle(GUI.skin.label) { fontSize = 10, normal = { textColor = Palette.TextFaint } };
            GUI.Label(new Rect(16, 22, 300, 14), "unity  (C#)", s);

            var lab = _labs[_labIndex];
            s = new GUIStyle(GUI.skin.label) { fontSize = 13, normal = { textColor = Palette.Text } };
            GUI.Label(new Rect(210, 6, 700, 16), $"{lab.Num:00}  {lab.Title}", s);
            s = new GUIStyle(GUI.skin.label) { fontSize = 10, normal = { textColor = Palette.TextDim } };
            GUI.Label(new Rect(210, 22, 700, 14), lab.Blurb, s);
        }

        private void BottomBar(float w, float h)
        {
            float y = h - 46;
            Draw.Rect(new Rect(0, y, w, 46), Palette.Panel);
            var clock = _active?.Clock;
            var stat = new GUIStyle(GUI.skin.label) { fontSize = 11, normal = { textColor = Palette.Text } };
            string line = clock != null
                ? $"RTT {clock.SmoothedRtt():F0} ms    JITTER {clock.Jitter():F0} ms    " +
                  $"INJECTED {DelayedConnection.PresetLabel}    IN FLIGHT {DelayedConnection.InFlight()} pkt    " +
                  $"ROOM {(_app.PrivateRoom ? "private" : "shared")}"
                : $"INJECTED {DelayedConnection.PresetLabel}    connecting...";
            GUI.Label(new Rect(16, y + 14, w - 32, 18), line, stat);

            stat = new GUIStyle(GUI.skin.label)
            { fontSize = 10, alignment = TextAnchor.MiddleRight, normal = { textColor = Palette.TextFaint } };
            GUI.Label(new Rect(w - 460, y + 14, 444, 18),
                "0-9 lab   L latency   D drop   P private", stat);
        }
    }
}
