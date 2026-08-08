/// Teardown in dependency order: lab wrappers → net_room → client.
if (lab != undefined) lab.detach(self);
if (net_room > 0) {
    colyseus_room_leave(net_room);
    colyseus_room_free(net_room);
}
if (client > 0) colyseus_client_free(client);
