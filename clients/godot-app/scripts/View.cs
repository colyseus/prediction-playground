using Godot;

namespace Playground
{
    /// <summary>
    /// WorldView + the arena's drawing vocabulary, ported from
    /// src/client/framework/draw.ts onto Godot's CanvasItem. Same 100x60
    /// world-unit arena letterboxed into the window, same palette as
    /// index.html, so a lab reads the same on both clients.
    /// </summary>
    public static class Palette
    {
        public static readonly Color Bg = Hex(0x0a0f1a);
        public static readonly Color Panel = Hex(0x0e1626);
        public static readonly Color Inset = Hex(0x121c30);
        public static readonly Color Border = Hex(0x24304a);
        public static readonly Color Text = Hex(0xd8e2f0);
        public static readonly Color TextDim = Hex(0x8aa0c0);
        public static readonly Color TextFaint = Hex(0x5e7196);
        public static readonly Color Accent = Hex(0xffd36b);
        public static readonly Color Good = Hex(0x7be08a);
        public static readonly Color Warn = Hex(0xffb454);
        public static readonly Color Bad = Hex(0xff6688);
        public static readonly Color Blue = Hex(0x6db3ff);

        private static Color Hex(int rgb) => new Color(
            ((rgb >> 16) & 0xff) / 255f, ((rgb >> 8) & 0xff) / 255f, (rgb & 0xff) / 255f, 1f);

        public static Color A(Color c, float alpha) { c.A = alpha; return c; }

        /// <summary>Player colour from the server hue byte — hsl(hue/256*360, 72%, 62%).</summary>
        public static Color Hue(int hue, float alpha = 1f)
        {
            float h = hue / 256f * 360f, s = 0.72f, l = 0.62f;
            float cc = (1 - Mathf.Abs(2 * l - 1)) * s;
            float hp = (h % 360f) / 60f;
            float x = cc * (1 - Mathf.Abs(hp % 2 - 1));
            float r = 0, g = 0, b = 0;
            if (hp < 1) { r = cc; g = x; }
            else if (hp < 2) { r = x; g = cc; }
            else if (hp < 3) { g = cc; b = x; }
            else if (hp < 4) { g = x; b = cc; }
            else if (hp < 5) { r = x; b = cc; }
            else { r = cc; b = x; }
            float m = l - cc / 2;
            return new Color(r + m, g + m, b + m, alpha);
        }
    }

    public class WorldView
    {
        public float Scale = 1, Ox, Oy;
        public Rect2 Stage;

        public void Fit(Rect2 stage, float margin = 28f)
        {
            Stage = stage;
            float sx = (stage.Size.X - margin * 2) / (float)Sim.ArenaW;
            float sy = (stage.Size.Y - margin * 2) / (float)Sim.ArenaH;
            Scale = Mathf.Min(sx, sy);
            Ox = stage.Position.X + (stage.Size.X - (float)Sim.ArenaW * Scale) / 2f;
            Oy = stage.Position.Y + (stage.Size.Y - (float)Sim.ArenaH * Scale) / 2f;
        }

        public float SX(double x) => Ox + (float)x * Scale;
        public float SY(double y) => Oy + (float)y * Scale;
        public float S(double len) => (float)len * Scale;

        /// <summary>Screen → world, for pointer aiming.</summary>
        public double WX(float sx) => (sx - Ox) / Scale;
        public double WY(float sy) => (sy - Oy) / Scale;
    }

    /// <summary>
    /// A bounded ring of world-space points, drawn as a fading polyline. Motion
    /// history is what makes a lag/prediction difference legible in a still frame,
    /// so several labs keep one per lane.
    /// </summary>
    public class Trail
    {
        private readonly Vector2[] _pts;
        private int _head, _count;

        public Trail(int capacity) { _pts = new Vector2[capacity]; }

        public void Push(double x, double y)
        {
            _pts[_head] = new Vector2((float)x, (float)y);
            _head = (_head + 1) % _pts.Length;
            if (_count < _pts.Length) _count++;
        }

        public void Clear() { _head = 0; _count = 0; }

        public void Render(WorldView v, Color c, float width = 1.5f, float maxAlpha = 0.4f)
        {
            for (int i = 1; i < _count; i++)
            {
                var a = _pts[(_head - _count + i - 1 + _pts.Length * 2) % _pts.Length];
                var b = _pts[(_head - _count + i + _pts.Length * 2) % _pts.Length];
                Draw.Line(new Vector2(v.SX(a.X), v.SY(a.Y)), new Vector2(v.SX(b.X), v.SY(b.Y)),
                    Palette.A(c, maxAlpha * i / _count), width);
            }
        }
    }

    /// <summary>
    /// Immediate-mode shapes over the CanvasItem being drawn this frame. The
    /// shell assigns <see cref="C"/> at the top of _Draw(); labs never see the
    /// node, only this vocabulary — which matches the web build's draw.ts.
    /// </summary>
    public static class Draw
    {
        /// <summary>The CanvasItem currently inside _Draw(). Set by the shell.</summary>
        public static CanvasItem C;

        private static Font _font;
        public static Font Font => _font ??= ThemeDB.FallbackFont;

        public static void Rect(Rect2 r, Color c) => C.DrawRect(r, c);

        public static void Line(Vector2 a, Vector2 b, Color c, float width = 1f)
        {
            if ((b - a).LengthSquared() < 0.0001f) return;
            C.DrawLine(a, b, c, width);
        }

        public static void Dashed(Vector2 a, Vector2 b, Color c, float width = 1f, float dash = 4f, float gap = 3f)
        {
            Vector2 d = b - a;
            float len = d.Length();
            if (len < 0.5f) return;
            Vector2 u = d / len;
            for (float t = 0; t < len; t += dash + gap)
                Line(a + u * t, a + u * Mathf.Min(t + dash, len), c, width);
        }

        public static void Square(WorldView v, double x, double y, double half, Color fill)
        {
            float s = v.S(half);
            Rect(new Rect2(v.SX(x) - s, v.SY(y) - s, s * 2, s * 2), fill);
        }

        public static void SquareOutline(WorldView v, double x, double y, double half, Color c, float w = 1f)
        {
            float s = v.S(half);
            float l = v.SX(x) - s, t = v.SY(y) - s, r = l + s * 2, b = t + s * 2;
            Rect(new Rect2(l, t, s * 2, w), c);
            Rect(new Rect2(l, b - w, s * 2, w), c);
            Rect(new Rect2(l, t, w, s * 2), c);
            Rect(new Rect2(r - w, t, w, s * 2), c);
        }

        /// <summary>Dashed outline "ghost" — the standard raw-server-pose marker.</summary>
        public static void GhostSquare(WorldView v, double x, double y, double half, Color c)
        {
            float s = v.S(half);
            float l = v.SX(x) - s, t = v.SY(y) - s, r = l + s * 2, b = t + s * 2;
            Dashed(new Vector2(l, t), new Vector2(r, t), c, 1.5f);
            Dashed(new Vector2(r, t), new Vector2(r, b), c, 1.5f);
            Dashed(new Vector2(r, b), new Vector2(l, b), c, 1.5f);
            Dashed(new Vector2(l, b), new Vector2(l, t), c, 1.5f);
        }

        public static void CircleOutline(WorldView v, double x, double y, double r, Color c, bool dashed = false)
        {
            const int seg = 28;
            float cx = v.SX(x), cy = v.SY(y), pr = v.S(r);
            for (int i = 0; i < seg; i += dashed ? 2 : 1)
            {
                float a0 = i * 2f * Mathf.Pi / seg, a1 = (i + 1) * 2f * Mathf.Pi / seg;
                Line(new Vector2(cx + Mathf.Cos(a0) * pr, cy + Mathf.Sin(a0) * pr),
                     new Vector2(cx + Mathf.Cos(a1) * pr, cy + Mathf.Sin(a1) * pr), c, 1.5f);
            }
        }

        /// <summary>Filled disc — bots, pucks, projectiles, pellets.</summary>
        public static void Circle(WorldView v, double x, double y, double r, Color c)
            => C.DrawCircle(new Vector2(v.SX(x), v.SY(y)), v.S(r), c);

        /// <summary>A dashed segment between two WORLD points.</summary>
        public static void DashedWorld(WorldView v, double x0, double y0, double x1, double y1,
            Color c, float width = 1f)
            => Dashed(new Vector2(v.SX(x0), v.SY(y0)), new Vector2(v.SX(x1), v.SY(y1)), c, width);

        /// <summary>Screen-space text — lane titles, captions, strip legends.</summary>
        public static void Text(float x, float y, float w, string text, Color c, int size = 11,
            HorizontalAlignment align = HorizontalAlignment.Left)
            => C.DrawString(Font, new Vector2(x, y + Font.GetAscent(size)), text, align, w, size, c);

        /// <summary>Word-wrapped screen-space text; returns the height consumed.</summary>
        public static float TextWrapped(float x, float y, float w, string text, Color c, int size = 11)
        {
            C.DrawMultilineString(Font, new Vector2(x, y + Font.GetAscent(size)), text,
                HorizontalAlignment.Left, w, size, -1, c);
            return Font.GetMultilineStringSize(text, HorizontalAlignment.Left, w, size).Y;
        }

        public static void Arena(WorldView v)
        {
            var grid = Palette.A(Palette.TextDim, 0.10f);
            for (int x = 10; x < (int)Sim.ArenaW; x += 10)
                Line(new Vector2(v.SX(x), v.SY(0)), new Vector2(v.SX(x), v.SY(Sim.ArenaH)), grid);
            for (int y = 10; y < (int)Sim.ArenaH; y += 10)
                Line(new Vector2(v.SX(0), v.SY(y)), new Vector2(v.SX(Sim.ArenaW), v.SY(y)), grid);
            var border = Palette.A(Palette.TextDim, 0.38f);
            Line(new Vector2(v.SX(0), v.SY(0)), new Vector2(v.SX(Sim.ArenaW), v.SY(0)), border, 1.5f);
            Line(new Vector2(v.SX(0), v.SY(Sim.ArenaH)), new Vector2(v.SX(Sim.ArenaW), v.SY(Sim.ArenaH)), border, 1.5f);
            Line(new Vector2(v.SX(0), v.SY(0)), new Vector2(v.SX(0), v.SY(Sim.ArenaH)), border, 1.5f);
            Line(new Vector2(v.SX(Sim.ArenaW), v.SY(0)), new Vector2(v.SX(Sim.ArenaW), v.SY(Sim.ArenaH)), border, 1.5f);
        }

        public static void Label(WorldView v, double x, double y, string text, Color c, int size = 11, float dy = 0)
            => Text(v.SX(x) - 90, v.SY(y) + dy, 180, text, c, size, HorizontalAlignment.Center);
    }
}
