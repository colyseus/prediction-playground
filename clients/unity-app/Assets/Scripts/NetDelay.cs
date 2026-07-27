using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;

namespace Playground
{
    /// <summary>
    /// Latency injector (APPS_PLAN §3). The web playground gets delay/jitter from
    /// the JS SDK's debug panel; on localhost every other SDK needs its own, or
    /// labs 00/01/03 demonstrate nothing.
    ///
    /// This wraps a room's <see cref="Connection"/> in place, the way the Lua
    /// client wraps `connection.emit`: capture <see cref="Connection.Dispatch"/>
    /// and <see cref="Connection.Transmit"/>, put a queue in front, and call the
    /// captured pair when a packet comes due. One seam each way, no subclass, and
    /// nothing global — each room gets its own injector.
    ///
    /// Two properties are load-bearing:
    ///
    ///  - No reordering: each packet's deliver-at is clamped to ≥ the previous
    ///    one's, because the wire is a stream and TCP never reorders (the JS
    ///    debug panel does the same).
    ///  - The wrap happens AFTER the join, so the handshake is never delayed —
    ///    only gameplay traffic is. That is what a real link looks like from the
    ///    room's point of view, and it means awaiting a join can't deadlock on a
    ///    queue nobody is draining yet.
    /// </summary>
    public class NetDelay
    {
        private struct Packet
        {
            public double DeliverAt;
            public Action Deliver;
        }

        public static double DelayMs;
        public static double JitterMs;

        private static readonly List<NetDelay> Live = new List<NetDelay>();
        private static readonly Random Rng = new Random(0x5EED);

        private readonly Queue<Packet> _inbound = new Queue<Packet>();
        private readonly Queue<Packet> _outbound = new Queue<Packet>();
        private double _inLast, _outLast;
        private readonly object _lock = new object();
        private readonly Connection _conn;

        private NetDelay(Connection conn) { _conn = conn; }

        /// <summary>
        /// Put an injector in front of a joined room's socket. Idempotent: a room
        /// that is already wrapped keeps its existing queue.
        /// </summary>
        public static NetDelay Wrap(Connection conn)
        {
            if (conn == null) return null;
            lock (Live)
            {
                foreach (var w in Live) if (w._conn == conn) return w;
            }

            var nd = new NetDelay(conn);
            var innerDispatch = conn.Dispatch;
            var innerTransmit = conn.Transmit;

            conn.Dispatch = e => nd.Enqueue(nd._inbound, ref nd._inLast, () => innerDispatch(e));
            conn.Transmit = data =>
            {
                nd.Enqueue(nd._outbound, ref nd._outLast, () => innerTransmit(data));
                return Task.CompletedTask;
            };

            lock (Live) Live.Add(nd);
            return nd;
        }

        public static void SetLatency(double delayMs, double jitterMs)
        {
            DelayMs = Math.Max(0, delayMs);
            JitterMs = Math.Max(0, jitterMs);
        }

        /// <summary>A named delay/jitter pair — what the `L` key cycles through.</summary>
        public readonly struct Preset
        {
            public readonly double Delay, Jitter;
            public readonly string Label;
            public Preset(double delay, double jitter, string label)
            {
                Delay = delay; Jitter = jitter; Label = label;
            }
        }

        public static readonly Preset[] Presets =
        {
            new Preset(0, 0, "off"),
            new Preset(80, 10, "80 ms + 10 jitter"),
            new Preset(200, 0, "200 ms"),
            new Preset(200, 80, "200 ms + 80 jitter"),
            new Preset(400, 60, "400 ms + 60 jitter"),
        };

        public static int PresetIndex { get; private set; }
        public static string PresetLabel => Presets[PresetIndex].Label;

        public static void UsePreset(int index)
        {
            PresetIndex = ((index % Presets.Length) + Presets.Length) % Presets.Length;
            SetLatency(Presets[PresetIndex].Delay, Presets[PresetIndex].Jitter);
        }

        public static void NextPreset() => UsePreset(PresetIndex + 1);

        /// <summary>Forget every socket and zero the latency — between test cases.</summary>
        public static void Reset()
        {
            lock (Live) Live.Clear();
            DelayMs = JitterMs = 0;
            PresetIndex = 0;
        }

        /// <summary>Kill every live socket, so the SDK sees a drop and not a leave.</summary>
        public static void DropAll()
        {
            NetDelay[] all;
            lock (Live) all = Live.ToArray();
            foreach (var w in all) w._conn.Drop();
        }

        public static int InFlight()
        {
            int n = 0;
            NetDelay[] all;
            lock (Live) all = Live.ToArray();
            foreach (var w in all) lock (w._lock) n += w._inbound.Count + w._outbound.Count;
            return n;
        }

        /// <summary>Drain everything due. Call once per frame from Update().</summary>
        public static void PumpAll()
        {
            double now = RoomClock.GetNow();
            NetDelay[] all;
            lock (Live) all = Live.ToArray();
            foreach (var w in all) w.Pump(now);
        }

        // Rng is shared across connections but Enqueue only holds the per-socket lock.
        private static double OneWay()
        {
            lock (Rng) return DelayMs + Rng.NextDouble() * JitterMs;
        }

        private void Enqueue(Queue<Packet> q, ref double last, Action deliver)
        {
            double at = RoomClock.GetNow() + OneWay();
            lock (_lock)
            {
                if (at < last) at = last;      // the wire never reorders
                last = at;
                q.Enqueue(new Packet { DeliverAt = at, Deliver = deliver });
            }
        }

        private void Pump(double now)
        {
            Drain(_outbound, now);
            Drain(_inbound, now);
        }

        private void Drain(Queue<Packet> q, double now)
        {
            while (true)
            {
                Packet p;
                lock (_lock)
                {
                    if (q.Count == 0 || q.Peek().DeliverAt > now) return;
                    p = q.Dequeue();
                }
                p.Deliver();      // outside the lock: this reaches the room
            }
        }
    }
}
