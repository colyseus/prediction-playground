using System;

namespace Playground
{
    /// <summary>
    /// A bounded ring of (time, value) samples. Several labs plot a signal
    /// against the server clock, and all of them want the same thing: push
    /// cheaply every frame, then walk the window in chronological order.
    /// </summary>
    public class Series
    {
        private readonly double[] _t, _v;
        private int _head;

        public int Count { get; private set; }

        public Series(int capacity)
        {
            _t = new double[capacity];
            _v = new double[capacity];
        }

        public void Push(double t, double value)
        {
            _t[_head] = t;
            _v[_head] = value;
            _head = (_head + 1) % _t.Length;
            if (Count < _t.Length) Count++;
        }

        public void Clear() { _head = 0; Count = 0; }

        /// <summary>Walk oldest → newest.</summary>
        public void ForEach(Action<double, double> visit)
        {
            int start = (_head - Count + _t.Length * 2) % _t.Length;
            for (int i = 0; i < Count; i++)
            {
                int k = (start + i) % _t.Length;
                visit(_t[k], _v[k]);
            }
        }
    }

    /// <summary>
    /// Coefficient of variation of rendered per-frame speed — the "limp" metric
    /// lab 04 scores its interpolation modes with. Constant speed scores 0; a
    /// mode that stutters between stalls and jumps scores high.
    /// </summary>
    public class Smoothness
    {
        // Sized for wall time, not frames: the harness has been seen running at
        // ~3300 fps, where even 600 samples span under 200 ms — less than four
        // patches, and a raw signal that only moves on a patch then looks
        // stationary. 4000 covers well over a second at that rate.
        private const int Cap = 4000;
        /// <summary>
        /// The window must span several patches before the ratio means anything.
        /// A raw (unsmoothed) signal only moves when a patch lands, so a window
        /// shorter than the patch interval sees nothing but zeroes and scores a
        /// mean of 0 — which reads as "no data" and is indistinguishable from a
        /// stationary entity. Frame rate decides how much wall time N samples
        /// cover, so the guard has to be in milliseconds, not samples.
        /// </summary>
        private const double MinWindowMs = 400;

        private readonly double[] _speeds = new double[Cap];
        private readonly double[] _dts = new double[Cap];
        private int _head, _count;
        private double _lastX, _lastY;
        private bool _seeded;

        public void Clear() { _head = 0; _count = 0; _seeded = false; }

        public void Sample(double x, double y, double dtMs)
        {
            if (_seeded && dtMs > 0)
            {
                double dx = x - _lastX, dy = y - _lastY;
                _speeds[_head] = Math.Sqrt(dx * dx + dy * dy) / dtMs * 1000.0;
                _dts[_head] = dtMs;
                _head = (_head + 1) % Cap;
                if (_count < Cap) _count++;
            }
            _lastX = x;
            _lastY = y;
            _seeded = true;
        }

        /// <summary>Why Cv() returned what it did — for a failing assertion to quote.</summary>
        public string Describe()
        {
            double span = 0, mean = 0;
            for (int i = 0; i < _count; i++) { span += _dts[i]; mean += _speeds[i]; }
            if (_count > 0) mean /= _count;
            return $"n={_count} span={span:F0}ms mean={mean:F2}u/s";
        }

        /// <summary>NaN until the window is long enough to mean anything.</summary>
        public double Cv()
        {
            if (_count < 20) return double.NaN;
            double span = 0;
            for (int i = 0; i < _count; i++) span += _dts[i];
            if (span < MinWindowMs) return double.NaN;

            double mean = 0;
            for (int i = 0; i < _count; i++) mean += _speeds[i];
            mean /= _count;
            if (mean < 0.5) return double.NaN;
            double var = 0;
            for (int i = 0; i < _count; i++) var += (_speeds[i] - mean) * (_speeds[i] - mean);
            return Math.Sqrt(var / _count) / mean;
        }
    }
}
