extends SceneTree
## Standalone relay node for multi-hop latency testing.
## Launched headless by the go-comparison test.
##
## Usage:
##   godot --headless --path <project> -s res://test/relay.gd -- \
##         --connect-to quic://127.0.0.1:XXXX --output-file /tmp/relay_uri.txt
##
## The relay starts a yggdrasil node, peers with the upstream node,
## starts its own TCP listener, and writes the listener URI to --output-file.
## It then idles until killed.

var _peer: YggdrasilPeer

func _init() -> void:
	var args = OS.get_cmdline_user_args()
	var connect_to := ""
	var output_file := ""

	var i := 0
	while i < args.size():
		match args[i]:
			"--connect-to":
				i += 1
				connect_to = args[i]
			"--output-file":
				i += 1
				output_file = args[i]
		i += 1

	if connect_to == "" or output_file == "":
		printerr("relay.gd: missing --connect-to or --output-file")
		quit(1)
		return

	_peer = YggdrasilPeer.new()

	# Build config with upstream peer
	var cfg = '{\n\t"MulticastInterfaces": [],\n\t"Peers": ["%s"]\n}' % connect_to
	var err = _peer.create_relay(cfg)
	if err != OK:
		printerr("relay.gd: create_relay failed: %s" % error_string(err))
		quit(1)
		return

	var listen_uri = _peer.start_listener("quic://127.0.0.1:0")
	if listen_uri == "":
		printerr("relay.gd: start_listener returned empty URI")
		_peer.close()
		quit(1)
		return

	# Write our listener URI so the parent process can read it
	var f = FileAccess.open(output_file, FileAccess.WRITE)
	if f == null:
		printerr("relay.gd: cannot write to %s" % output_file)
		_peer.close()
		quit(1)
		return
	f.store_string(listen_uri)
	f.close()

	print("relay.gd: listening on %s (peered to %s)" % [listen_uri, connect_to])
	# Keep running — the parent test will kill this process when done.
