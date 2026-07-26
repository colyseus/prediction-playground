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
    /// Installed through Client.ConnectionFactory, so the room builds one of
    /// these instead of a plain Connection. Both directions are queued and
    /// drained from Update(). Two properties are load-bearing:
    ///
    ///  - No reordering: each packet's deliver-at is clamped to >= the previous
    ///    one's, because the wire is a stream and TCP never reorders (the JS
    ///    debug panel does the same).
    ///  - Inbound is intercepted at RaiseMessage, NOT by subscribing to
    ///    OnMessage: a subscriber runs alongside the room's handler rather than
    ///    in front of it, so it could not delay anything.
    /// </summary>
    public class DelayedConnection : Connection
    {
        private struct Packet
        {
            public double DeliverAt;
            public byte[] Data;
            public int Code;
            public string Text;
            public int Kind;   // 0 open, 1 message, 2 close, 3 error
        }

        public static double DelayMs;
        public static double JitterMs;

        private static readonly List<DelayedConnection> Live = new List<DelayedConnection>();
        private static readonly Random Rng = new Random(0x5EED);

        private readonly Queue<Packet> _inbound = new Queue<Packet>();
        private readonly Queue<Packet> _outbound = new Queue<Packet>();
        private double _inLast, _outLast;
        private readonly object _lock = new object();

        public DelayedConnection(string url, Dictionary<string, string> headers) : base(url, headers)
        {
            lock (Live) Live.Add(this);
        }

        /// <summary>Point Client.ConnectionFactory at us. Call once at startup.</summary>
        public static void Install()
        {
            Client.ConnectionFactory = (url, headers) => new DelayedConnection(url, headers);
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
            DelayedConnection[] all;
            lock (Live) all = Live.ToArray();
            foreach (var c in all) c.Drop();
        }

        public static int InFlight()
        {
            int n = 0;
            DelayedConnection[] all;
            lock (Live) all = Live.ToArray();
            foreach (var c in all) lock (c._lock) n += c._inbound.Count + c._outbound.Count;
            return n;
        }

        /// <summary>Drain everything due. Call once per frame from Update().</summary>
        public static void PumpAll()
        {
            double now = RoomClock.GetNow();
            DelayedConnection[] all;
            lock (Live) all = Live.ToArray();
            foreach (var c in all) c.Pump(now);
        }

        // Rng is shared across connections but Enqueue only holds the per-socket lock.
        private static double OneWay()
        {
            lock (Rng) return DelayMs + Rng.NextDouble() * JitterMs;
        }

        private static void Enqueue(Queue<Packet> q, ref double last, Packet p, double now)
        {
            double at = now + OneWay();
            if (at < last) at = last;      // the wire never reorders
            last = at;
            p.DeliverAt = at;
            q.Enqueue(p);
        }

        protected override void RaiseOpen()
        {
            lock (_lock) Enqueue(_inbound, ref _inLast, new Packet { Kind = 0 }, RoomClock.GetNow());
        }

        protected override void RaiseMessage(byte[] data)
        {
            lock (_lock) Enqueue(_inbound, ref _inLast, new Packet { Kind = 1, Data = data }, RoomClock.GetNow());
        }

        protected override void RaiseClose(int code)
        {
            lock (_lock) Enqueue(_inbound, ref _inLast, new Packet { Kind = 2, Code = code }, RoomClock.GetNow());
        }

        protected override void RaiseError(string message)
        {
            lock (_lock) Enqueue(_inbound, ref _inLast, new Packet { Kind = 3, Text = message }, RoomClock.GetNow());
        }

        public override Task Send(byte[] data)
        {
            lock (_lock) Enqueue(_outbound, ref _outLast, new Packet { Kind = 1, Data = data }, RoomClock.GetNow());
            return Task.CompletedTask;
        }

        private void Pump(double now)
        {
            while (true)
            {
                Packet p;
                lock (_lock)
                {
                    if (_outbound.Count == 0 || _outbound.Peek().DeliverAt > now) break;
                    p = _outbound.Dequeue();
                }
                base.Send(p.Data);
            }

            while (true)
            {
                Packet p;
                lock (_lock)
                {
                    if (_inbound.Count == 0 || _inbound.Peek().DeliverAt > now) break;
                    p = _inbound.Dequeue();
                }
                switch (p.Kind)
                {
                    case 0: base.RaiseOpen(); break;
                    case 1: base.RaiseMessage(p.Data); break;
                    // Reconnect builds a fresh Connection, so a closed one is done.
                    case 2: base.RaiseClose(p.Code); lock (Live) Live.Remove(this); return;
                    case 3: base.RaiseError(p.Text); break;
                }
            }
        }
    }
}
