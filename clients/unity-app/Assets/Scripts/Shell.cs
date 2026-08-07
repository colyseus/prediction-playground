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
        /// What the caller needs decoded BEYOND the first full sync (which
        /// <c>WaitForFirstState</c> already guarantees) — e.g. the bot's entry
        /// in the players map. Most labs can omit it.
        /// </param>
        public static async Task<Room<T>> JoinLab<T>(App app, string name, Func<Room<T>, bool> ready = null)
            where T : ColyseusSchema
        {
            var room = app.PrivateRoom
                ? await app.Client.Create<T>(name)
                : await app.Client.JoinOrCreate<T>(name);
            // In front of the room's own listeners, but only now that it has
            // joined: the handshake rides an undelayed link, gameplay does not.
            NetDelay.Wrap(room.Connection);
            // collections are null until the first full sync; capped so a dead
            // server still hands the room back for the caller's own checks
            await Task.WhenAny(room.WaitForFirstState(), Task.Delay(5000));
            for (int i = 0; ready != null && !ready(room) && i < 200; i++)
            {
                await Task.Delay(25);
            }
            return room;
        }
    }

}
