using Godot;

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

        public void Begin(float x, float y, float w)
        {
            _x = x; _y = y; _w = w; _cursor = y;
        }

        public void Section(string title)
        {
            _cursor += 10;
            Draw.Text(_x, _cursor, _w, title, Palette.TextFaint, 10);
            _cursor += 14;
            Draw.Rect(new Rect2(_x, _cursor, _w, 1), Palette.Border);
            _cursor += 6;
        }

        public void Row(string label, string value, Color valueColor)
        {
            Draw.Text(_x, _cursor, _w, label, Palette.TextDim, 12);
            Draw.Text(_x, _cursor, _w, value, valueColor, 12, HorizontalAlignment.Right);
            _cursor += 18;
        }

        public void Key(string key, string what)
        {
            Draw.Rect(new Rect2(_x, _cursor - 1, 58, 15), Palette.Inset);
            Draw.Text(_x + 4, _cursor - 2, 60, key, Palette.Text, 10);
            Draw.Text(_x + 64, _cursor - 2, _w - 64, what, Palette.TextDim, 10);
            _cursor += 17;
        }

        public void Note(string text)
        {
            float h = Draw.TextWrapped(_x, _cursor, _w, text, Palette.TextFaint, 10);
            _cursor += h + 6;
        }

        /// <summary>One chip per pending (unacked) input — drains as acks land.</summary>
        public void Chips(string label, int n, int max = 48)
        {
            Row(label, n.ToString(), Palette.Accent);
            float cx = _x, cy = _cursor;
            for (int i = 0; i < Mathf.Min(n, max); i++)
            {
                Draw.Rect(new Rect2(cx, cy, 5, 10), Palette.A(Palette.Accent, 0.75f));
                cx += 7;
                if (cx + 5 > _x + _w) { cx = _x; cy += 12; }
            }
            _cursor = cy + 18;
        }

        public void Spark(Spark s, string label, string value, Color color, double fixedMax = 0)
        {
            Row(label, value, color);
            const float gh = 30;
            var box = new Rect2(_x, _cursor, _w, gh);
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

        public void Render(Rect2 box, Color color, double fixedMax)
        {
            if (_count < 2) return;
            double max = fixedMax;
            if (max <= 0) { for (int i = 0; i < _count; i++) if (_data[i] > max) max = _data[i]; }
            if (max <= 0) max = 1e-6;
            int start = (_head - _count + Cap * 2) % Cap;
            for (int i = 1; i < _count; i++)
            {
                double v0 = _data[(start + i - 1) % Cap], v1 = _data[(start + i) % Cap];
                float x0 = box.Position.X + (i - 1) / (float)(Cap - 1) * box.Size.X;
                float x1 = box.Position.X + i / (float)(Cap - 1) * box.Size.X;
                float y0 = box.End.Y - 2 - (float)System.Math.Min(1, v0 / max) * (box.Size.Y - 4);
                float y1 = box.End.Y - 2 - (float)System.Math.Min(1, v1 / max) * (box.Size.Y - 4);
                Draw.Line(new Vector2(x0, y0), new Vector2(x1, y1), color);
            }
        }
    }
}
