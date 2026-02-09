extends Node
## Bootstrapper that sets up Yggdrasil mesh networking for multiplayer.
## Replaces ENet with YggdrasilPeer for all host/client connections.
## Add this node to your scene and configure via exports or call host()/join() directly.

@export_category("Yggdrasil")
## The yggdrasil config JSON. Use "{}" for auto-generated defaults with multicast.
## Set MulticastInterfaces to enable LAN peer discovery.
@export_multiline var yggdrasil_config: String = '{
	"MulticastInterfaces": [
		{
			"Regex": ".*",
			"Beacon": true,
			"Listen": true,
			"Port": 0,
			"Priority": 0
		}
	]
}'

## Optional: URI of a remote yggdrasil peer to connect to (e.g. "quic://1.2.3.4:5678").
## Leave empty for LAN-only multicast discovery.
## Transport protocol is set in Project Settings > Yggdrasil > Transport > Protocol.
@export var remote_peer_uri: String = ""

@export_category("UI")
@export var connect_ui: Control
@export var address_input: LineEdit
@export var status_label: Label

var _peer: YggdrasilPeer = null
var _debug_timer: float = 0.0

func host():
	if _peer != null:
		_peer.close()

	_peer = YggdrasilPeer.new()

	var err = _peer.create_host(yggdrasil_config)
	if err != OK:
		print("[YggBootstrap] Failed to create host: ", error_string(err))
		if status_label:
			status_label.text = "Failed to start host"
		return err

	if remote_peer_uri != "":
		_peer.add_yggdrasil_peer(remote_peer_uri)

	get_tree().get_multiplayer().multiplayer_peer = _peer
	get_tree().get_multiplayer().server_relay = true

	print("[YggBootstrap] Host started on yggdrasil address: ", _peer.get_yggdrasil_address())
	print("[YggBootstrap] Public key: ", _peer.get_yggdrasil_public_key())

	if connect_ui:
		connect_ui.hide()
	if status_label:
		status_label.text = "Host: " + _peer.get_yggdrasil_public_key()

	# Start NetworkTime if available
	if has_node("/root/NetworkTime"):
		get_node("/root/NetworkTime").start()

	return OK

func join(server_identity: String = ""):
	if server_identity == "" and address_input:
		server_identity = address_input.text.strip_edges()

	# Auto-discover host on LAN if no identity or "localhost" entered
	if server_identity == "" or server_identity == "localhost":
		print("[YggBootstrap] Auto-discovering host on LAN...")
		if status_label:
			status_label.text = "Discovering..."
		var discovered = await YggdrasilDiscovery.find_lan_peers(get_tree(), yggdrasil_config)
		if discovered.is_empty():
			print("[YggBootstrap] No peers found on LAN")
			if status_label:
				status_label.text = "No host found"
			return ERR_CANT_RESOLVE

		for key in discovered:
			print("[YggBootstrap] Trying discovered peer %s ..." % key)
			if status_label:
				status_label.text = "Trying " + key.substr(0, 8) + "..."
			var result = await _try_connect(key)
			if result == OK:
				if address_input:
					address_input.text = key
				return OK
			print("[YggBootstrap] %s did not accept" % key)

		if status_label:
			status_label.text = "No game host found"
		return ERR_CANT_CONNECT

	return await _try_connect(server_identity)

func _try_connect(server_identity: String) -> Error:
	if _peer != null:
		_peer.close()

	_peer = YggdrasilPeer.new()

	# Accepts either public key hex (64 chars) or IPv6 address
	var err = _peer.create_client(server_identity, yggdrasil_config)
	if err != OK:
		print("[YggBootstrap] Failed to connect: ", error_string(err))
		if status_label:
			status_label.text = "Failed to connect"
		return err

	if remote_peer_uri != "":
		_peer.add_yggdrasil_peer(remote_peer_uri)

	# Setting as multiplayer_peer ensures _poll() is called for connect retries
	get_tree().get_multiplayer().multiplayer_peer = _peer

	print("[YggBootstrap] Connecting to server: ", server_identity)
	print("[YggBootstrap] Our yggdrasil address: ", _peer.get_yggdrasil_address())

	if status_label:
		status_label.text = "Connecting..."

	# Wait for connection (_poll retries connect request until session establishes)
	await _wait_for_connection()

	if _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		print("[YggBootstrap] Connection failed!")
		_peer.close()
		_peer = null
		get_tree().get_multiplayer().multiplayer_peer = null
		if status_label:
			status_label.text = "Connection failed"
		return ERR_CANT_CONNECT

	print("[YggBootstrap] Connected! peer_id=", _peer.get_unique_id())
	if connect_ui:
		connect_ui.hide()
	if status_label:
		status_label.text = "Connected (peer " + str(_peer.get_unique_id()) + ")"

	if has_node("/root/NetworkTime"):
		get_node("/root/NetworkTime").start()

	return OK

func _wait_for_connection():
	var timeout = 10.0
	var elapsed = 0.0
	while elapsed < timeout:
		if _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return
		if _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1

func _process(delta):
	# Periodic debug output
	if _peer == null:
		return

	_debug_timer += delta
	if _debug_timer >= 5.0:
		_debug_timer = 0.0
		_print_debug_info()

func _print_debug_info():
	if _peer == null or _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return

	print("--- [YggDebug] Network Status ---")
	print("  Address: ", _peer.get_yggdrasil_address())
	print("  Peer ID: ", _peer.get_unique_id())
	print("  Is Server: ", _peer.get_unique_id() == 1)
	print("  Status: ", _connection_status_str())
	print("  MTU: ", _peer.get_yggdrasil_mtu())
	print("  Yggdrasil Peers: ", _peer.get_peers_info())
	print("  Sessions: ", _peer.get_sessions_info())
	print("--- [YggDebug] End ---")

func _connection_status_str() -> String:
	match _peer.get_connection_status():
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			return "Disconnected"
		MultiplayerPeer.CONNECTION_CONNECTING:
			return "Connecting"
		MultiplayerPeer.CONNECTION_CONNECTED:
			return "Connected"
	return "Unknown"

func _exit_tree():
	if _peer != null:
		_peer.close()
		_peer = null
