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
        private const int Cap = 120;

        private readonly double[] _speeds = new double[Cap];
        private int _head, _count;
        private double _lastX, _lastY;
        private bool _seeded;

        public void Sample(double x, double y, double dtMs)
        {
            if (_seeded && dtMs > 0)
            {
                double dx = x - _lastX, dy = y - _lastY;
                _speeds[_head] = Math.Sqrt(dx * dx + dy * dy) / dtMs * 1000.0;
                _head = (_head + 1) % Cap;
                if (_count < Cap) _count++;
            }
            _lastX = x;
            _lastY = y;
            _seeded = true;
        }

        /// <summary>NaN when there isn't enough motion for the ratio to mean anything.</summary>
        public double Cv()
        {
            if (_count < 20) return double.NaN;
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
