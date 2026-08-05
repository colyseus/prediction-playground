class_name Shell
## Join helper — the shell owns joining so labs never do.

## Multiple clients land in the SAME room by default (multiplayer is free);
## `P` forces a solo room, mirroring the web build's ?private=1.
##
## `ready` is what the caller needs decoded before it can wire up — waiting on
## joined alone is NOT enough: collections stay empty until a patch fills them
## in, so a lab that reaches for state.players mounts on nothing.
static func join_lab(app: App, lab_name: String, ready := Callable()):
	var room = app.client.create(lab_name) if app.private_room \
		else app.client.join_or_create(lab_name)
	if room == null: return null

	var flags := { "joined": false, "failed": false }
	room.joined.connect(func(): flags["joined"] = true)
	room.error.connect(func(_code, _msg): flags["failed"] = true)
	room.left.connect(func(_code, _reason): flags["failed"] = true)

	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + 8000
	while not flags["joined"] and not flags["failed"] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not flags["joined"]: return null

	# In front of the room's own traffic, but only now that it has joined:
	# the handshake rides an undelayed link, gameplay does not.
	NetDelay.wrap(room)

	deadline = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		NetDelay.pump_all()
		if not ready.is_valid() or ready.call(room): break
		await tree.process_frame
	return room
