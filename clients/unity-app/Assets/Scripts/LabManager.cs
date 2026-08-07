using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using ColyseusSchema = Colyseus.Schema.Schema;
using UnityEngine;

namespace Playground
{
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

            _app.Client = new Client(Endpoint);
            _labs = new ILab[] { new Lab00(), new Lab01(), new Lab02(), new Lab03(), new Lab04(), new Lab05(), new Lab06(), new Lab07(), new Lab08(), new Lab09(), new Lab10(), new Lab11() };
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
                }
                else _error = $"state never arrived for {lab.Id}";
            }
            catch (Exception e) { _error = e.Message; }
            finally { _switching = false; }
        }

        private void Update()
        {
            // Deliver due packets first: the injector queues both directions and
            // only drains here, on the main thread.
            NetDelay.PumpAll();

            double now = RoomClock.GetNow();
            double dt = _lastNow > 0 ? now - _lastNow : 0;
            _lastNow = now;

            // Guard on the lab NUMBER, not the index: `i < 9` capped this at
            // index 8, and since the labs are ordered 00..11 that silently made
            // lab 09 unreachable from the keyboard. Digits map 0-9 to labs
            // 00-09, matching the haxe and defold shells.
            for (int i = 0; i < _labs.Length; i++)
            {
                int n = _labs[i].Num;
                if (n < 10 && Kb.Key(KeyCode.Alpha0 + n)) _ = SwitchTo(i);
            }
            // The digits only reach labs 0-9; [ ] are the only way to a 2-digit lab.
            if (Kb.Key(KeyCode.LeftBracket)) _ = SwitchTo((_labIndex + _labs.Length - 1) % _labs.Length);
            if (Kb.Key(KeyCode.RightBracket)) _ = SwitchTo((_labIndex + 1) % _labs.Length);
            if (Kb.Key(KeyCode.L)) NetDelay.NextPreset();
            if (Kb.Key(KeyCode.K)) NetDelay.DropAll();
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
                  $"INJECTED {NetDelay.PresetLabel}    IN FLIGHT {NetDelay.InFlight()} pkt    " +
                  $"ROOM {(_app.PrivateRoom ? "private" : "shared")}"
                : $"INJECTED {NetDelay.PresetLabel}    connecting...";
            GUI.Label(new Rect(16, y + 14, w - 32, 18), line, stat);

            stat = new GUIStyle(GUI.skin.label)
            { fontSize = 10, alignment = TextAnchor.MiddleRight, normal = { textColor = Palette.TextFaint } };
            GUI.Label(new Rect(w - 460, y + 14, 444, 18),
                "0-9 lab   [ ] prev/next   L latency   K drop   P private", stat);
        }
    }
}
