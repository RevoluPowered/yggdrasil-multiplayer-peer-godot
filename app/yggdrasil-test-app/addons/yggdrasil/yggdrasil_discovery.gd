extends RefCounted
class_name YggdrasilDiscovery
## Discovers yggdrasil peers on the local network via multicast.
##
## How it works:
## 1. Starts a temporary yggdrasil node with multicast enabled
## 2. Waits for LAN peers to appear in the yggdrasil peer list
## 3. Returns discovered peer public keys (used for create_client)
##
## Note: Discovery only finds yggdrasil peers on the network. The caller
## should attempt to connect to each key to verify it is a game host.
## Connection verification requires the peer to be set as multiplayer_peer
## so that _poll() is called by the engine for connect retries.

const POLL_INTERVAL := 0.1
const DEFAULT_TIMEOUT := 8.0
const GRACE_AFTER_FIRST := 0.5

## Discover peers on LAN and return their public key hex strings.
## Starts a temporary node, waits for multicast discovery, then returns found keys.
static func find_lan_peers(tree: SceneTree, config: String = '{"MulticastInterfaces":[{"Regex":".*","Beacon":true,"Listen":true,"Port":0}]}', timeout: float = DEFAULT_TIMEOUT) -> PackedStringArray:
	var peer = YggdrasilPeer.new()
	# Start as host just to bootstrap the yggdrasil node and enable multicast
	var err = peer.create_host(config)
	if err != OK:
		print("[YggDiscovery] Failed to start discovery node: %s" % error_string(err))
		return PackedStringArray()

	var own_key = peer.get_yggdrasil_public_key()
	print("[YggDiscovery] Discovery node started (key=%s), scanning for LAN peers..." % own_key.substr(0, 16))

	var found: PackedStringArray = []
	var elapsed := 0.0
	var first_found_at := -1.0

	while elapsed < timeout:
		await tree.create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL

		var json_str = peer.get_peers_info()
		if json_str == "" or json_str == "{}" or json_str == "null":
			continue

		var parsed = JSON.parse_string(json_str)
		if parsed == null or not (parsed is Array):
			continue

		for p in parsed:
			if p is Dictionary and p.has("KeyHex"):
				var key_hex: String = p["KeyHex"]
				if key_hex != "" and key_hex != own_key and key_hex not in found:
					var ip: String = p.get("IP", "")
					found.append(key_hex)
					print("[YggDiscovery] Found peer: %s (ip=%s)" % [key_hex.substr(0, 16), ip])
					if first_found_at < 0:
						first_found_at = elapsed

		# Once we found a peer, give a short grace period for more then stop
		if first_found_at >= 0 and (elapsed - first_found_at) >= GRACE_AFTER_FIRST:
			break

	peer.close()
	print("[YggDiscovery] Discovery complete. Found %d peer(s)." % found.size())
	return found

## Discover LAN peers and return the first one found (public key hex).
## The caller is responsible for actually connecting (via create_client + setting
## as multiplayer_peer) to verify it is a game host.
static func find_host(tree: SceneTree, config: String = '{"MulticastInterfaces":[{"Regex":".*","Beacon":true,"Listen":true,"Port":0}]}', timeout: float = DEFAULT_TIMEOUT) -> String:
	var peers = await find_lan_peers(tree, config, timeout)
	if peers.is_empty():
		print("[YggDiscovery] No peers found on LAN")
		return ""

	print("[YggDiscovery] Returning first discovered peer: %s" % peers[0].substr(0, 16))
	return peers[0]
