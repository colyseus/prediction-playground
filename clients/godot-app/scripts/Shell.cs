using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Colyseus;
using Colyseus.Predict;
using ColyseusSchema = Colyseus.Schema.Schema;

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
            // In front of the room's own listeners, but only now that it has
            // joined: the handshake rides an undelayed link, gameplay does not.
            NetDelay.Wrap(room.Connection);
            for (int i = 0; i < 200; i++)
            {
                if (room.State != null && (ready == null || ready(room))) break;
                await Task.Delay(25);
            }
            return room;
        }
    }

}
