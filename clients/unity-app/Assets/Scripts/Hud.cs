using System.Collections.Generic;
using UnityEngine;

namespace Playground
{
    /// <summary>
    /// Immediate-mode side panel: telemetry rows, sparklines, pending-input
    /// chips, and the keyboard "controls" list that stands in for the web
    /// build's sliders and toggles. Port of framework/hud.ts + controls.ts.
    /// </summary>
    public class Hud
    {
        private float _x, _y, _w, _cursor;
        private GUIStyle _row, _small, _key;

        public void Begin(float x, float y, float w)
        {
            _x = x; _y = y; _w = w; _cursor = y;
            if (_row == null)
            {
                _row = new GUIStyle(GUI.skin.label) { fontSize = 12, padding = new RectOffset(0, 0, 0, 0) };
                _small = new GUIStyle(GUI.skin.label) { fontSize = 10, padding = new RectOffset(0, 0, 0, 0) };
                _key = new GUIStyle(GUI.skin.label) { fontSize = 10, padding = new RectOffset(0, 0, 0, 0) };
            }
        }

        public void Section(string title)
        {
            _cursor += 10;
            _small.normal.textColor = Palette.TextFaint;
            GUI.Label(new Rect(_x, _cursor, _w, 14), title, _small);
            _cursor += 14;
            Draw.Rect(new Rect(_x, _cursor, _w, 1), Palette.Border);
            _cursor += 6;
        }

        public void Row(string label, string value, Color valueColor)
        {
            _row.normal.textColor = Palette.TextDim;
            _row.alignment = TextAnchor.UpperLeft;
            GUI.Label(new Rect(_x, _cursor, _w, 16), label, _row);
            _row.normal.textColor = valueColor;
            _row.alignment = TextAnchor.UpperRight;
            GUI.Label(new Rect(_x, _cursor, _w, 16), value, _row);
            _row.alignment = TextAnchor.UpperLeft;
            _cursor += 18;
        }

        public void Key(string key, string what)
        {
            var box = new Rect(_x, _cursor - 1, 58, 15);
            Draw.Rect(box, Palette.Inset);
            _key.normal.textColor = Palette.Text;
            GUI.Label(new Rect(box.x + 4, _cursor - 2, 60, 15), key, _key);
            _key.normal.textColor = Palette.TextDim;
            GUI.Label(new Rect(_x + 64, _cursor - 2, _w - 64, 15), what, _key);
            _cursor += 17;
        }

        public void Note(string text)
        {
            _small.normal.textColor = Palette.TextFaint;
            _small.wordWrap = true;
            float h = _small.CalcHeight(new GUIContent(text), _w);
            GUI.Label(new Rect(_x, _cursor, _w, h), text, _small);
            _cursor += h + 6;
        }

        /// <summary>One chip per pending (unacked) input — drains as acks land.</summary>
        public void Chips(string label, int n, int max = 48)
        {
            Row(label, n.ToString(), Palette.Accent);
            float cx = _x, cy = _cursor;
            for (int i = 0; i < Mathf.Min(n, max); i++)
            {
                Draw.Rect(new Rect(cx, cy, 5, 10), Palette.A(Palette.Accent, 0.75f));
                cx += 7;
                if (cx + 5 > _x + _w) { cx = _x; cy += 12; }
            }
            _cursor = cy + 18;
        }

        public void Spark(Spark s, string label, string value, Color color, double fixedMax = 0)
        {
            Row(label, value, color);
            const float gh = 30;
            var box = new Rect(_x, _cursor, _w, gh);
            Draw.Rect(box, Palette.Inset);
            s.Render(box, color, fixedMax);
            _cursor += gh + 8;
        }
    }

    /// <summary>Rolling graph; auto-scales to the window max unless given one.</summary>
    public class Spark
    {
        private const int Cap = 140;
        private readonly double[] _data = new double[Cap];
        private int _head, _count;

        public void Push(double v)
        {
            _data[_head] = v;
            _head = (_head + 1) % Cap;
            if (_count < Cap) _count++;
        }

        public double Last => _count == 0 ? 0 : _data[(_head - 1 + Cap) % Cap];

        public void Render(Rect box, Color color, double fixedMax)
        {
            if (_count < 2) return;
            double max = fixedMax;
            if (max <= 0) { for (int i = 0; i < _count; i++) if (_data[i] > max) max = _data[i]; }
            if (max <= 0) max = 1e-6;
            int start = (_head - _count + Cap * 2) % Cap;
            for (int i = 1; i < _count; i++)
            {
                double v0 = _data[(start + i - 1) % Cap], v1 = _data[(start + i) % Cap];
                float x0 = box.x + (i - 1) / (float)(Cap - 1) * box.width;
                float x1 = box.x + i / (float)(Cap - 1) * box.width;
                float y0 = box.yMax - 2 - (float)System.Math.Min(1, v0 / max) * (box.height - 4);
                float y1 = box.yMax - 2 - (float)System.Math.Min(1, v1 / max) * (box.height - 4);
                Draw.Line(new Vector2(x0, y0), new Vector2(x1, y1), color);
            }
        }
    }
}
