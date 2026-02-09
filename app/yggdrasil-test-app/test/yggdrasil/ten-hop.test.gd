extends VestTest
## Multi-hop relay test matching Go TestCAPIStyleWithCallPeer pattern.
## Creates: server ← relay0 ← ... ← relay(N-2) ← client (NUM_HOPS hops)
## Key: create ALL nodes first, start listeners, THEN chain with CallPeer.

const NUM_HOPS := 32  # Total hops: server + (NUM_HOPS - 1) relays + client

var _tree: SceneTree
var server: YggdrasilPeer
var client: YggdrasilPeer
var relays: Array = []
var relay_uris: Array = []
var server_mp: SceneMultiplayer
var client_mp: SceneMultiplayer

func get_suite_name() -> String:
	return "%dHop" % NUM_HOPS

func before_case(_case_def):
	if not _tree:
		_tree = Vest.get_tree()

# Aggressively poll both multiplayer instances to speed up packet processing
func _poll_all():
	if server_mp: server_mp.poll()
	if client_mp: client_mp.poll()

func suite() -> void:
	var num_relays = NUM_HOPS - 1
	define("%d-hop relay chain" % NUM_HOPS, func():
		test("create all nodes and chain (Go test pattern)", func():
			# --- Step 1: Create server ---
			var sw = Node.new(); sw.name = "TenHopSrv"
			_tree.root.add_child(sw)
			server = YggdrasilPeer.new()
			server.debug_logging = true
			var err = server.create_host('{"MulticastInterfaces": [], "Listen": []}')
			expect_equal(err, OK, "server create_host")
			var server_uri = server.start_listener("quic://127.0.0.1:0")
			expect_not_empty(server_uri, "server listener")
			print("  Server: %s (key: %s)" % [server_uri, server.get_yggdrasil_public_key()])
			server_mp = SceneMultiplayer.new()
			server_mp.server_relay = true
			server_mp.multiplayer_peer = server
			_tree.set_multiplayer(server_mp, ^"/root/TenHopSrv")

			# --- Step 2: Create ALL relays (no connections yet) ---
			for i in num_relays:
				var relay = YggdrasilPeer.new()
				err = relay.create_relay('{"MulticastInterfaces": [], "Listen": []}')
				expect_equal(err, OK, "relay %d create_relay" % i)
				relays.append(relay)

			# --- Step 3: Start ALL listeners ---
			relay_uris.append(server_uri)  # index 0 = server
			for i in num_relays:
				var uri = relays[i].start_listener("quic://127.0.0.1:0")
				expect_not_empty(uri, "relay %d listener" % i)
				relay_uris.append(uri)  # index i+1 = relay[i]
				print("  Relay %d: %s" % [i, uri])

			# --- Step 4: Chain ALL at once (matching Go test pattern) ---
			for i in num_relays:
				err = relays[i].add_yggdrasil_peer(relay_uris[i])  # relay[i] → prev
				expect_equal(err, OK, "relay %d add_peer" % i)
			print("  All %d relays chained via CallPeer" % num_relays)
		)

		test("wait for partial tree convergence (20s, tree >= 2)", func():
			# Go test only requires tree >= 2 per node, then 1s pause.
			# Full convergence is NOT required — Ironwood routes with partial tree.
			var all_nodes: Array = [server] + relays
			var start = Time.get_ticks_msec()
			var deadline = start + 20000
			var last_log = start
			while true:
				var min_tree = 999
				var all_ready = true
				for node in all_nodes:
					var t = node.get_tree_entries()
					if t < 2:
						all_ready = false
					min_tree = min(min_tree, t)
				if all_ready:
					print("  All nodes have tree >= 2 (%dms)" % [Time.get_ticks_msec() - start])
					break
				if Time.get_ticks_msec() > deadline:
					print("  WARNING: not all nodes have tree >= 2 after 20s (min=%d)" % min_tree)
					for i in all_nodes.size():
						print("    node %d: tree=%d" % [i, all_nodes[i].get_tree_entries()])
					break  # Continue anyway — don't fail
				if Time.get_ticks_msec() - last_log > 5000:
					print("  [%.0fs] min tree=%d" % [
						(Time.get_ticks_msec() - start) / 1000.0, min_tree])
					last_log = Time.get_ticks_msec()
				await _tree.process_frame
			# Brief pause like Go test
			print("  Pausing 1s for routing table propagation...")
			var pause_start = Time.get_ticks_msec()
			while Time.get_ticks_msec() - pause_start < 1000:
				await _tree.process_frame
			# Log tree state and assert
			var all_nodes2: Array = [server] + relays
			var final_min_tree = 999
			for i in all_nodes2.size():
				var t = all_nodes2[i].get_tree_entries()
				if OS.is_stdout_verbose():
					print("    node %d: tree=%d" % [i, t])
				final_min_tree = min(final_min_tree, t)
			expect_true(final_min_tree >= 2, "all nodes should have tree >= 2 (min=%d)" % final_min_tree)
		)

		test("create client via relay %d (%d hops to server)" % [num_relays - 1, NUM_HOPS], func():
			var cw = Node.new(); cw.name = "TenHopCli"
			_tree.root.add_child(cw)
			client = YggdrasilPeer.new()
			client.debug_logging = true
			client.packet_dropped.connect(func(key, error):
				print("  [DROP] client → %s: %s" % [key.substr(0, 8), error])
			)
			server.packet_dropped.connect(func(key, error):
				print("  [DROP] server → %s: %s" % [key.substr(0, 8), error])
			)
			var last_relay_uri = relay_uris[num_relays]  # last relay's listener
			var server_key = server.get_yggdrasil_public_key()
			print("  Client peering via: %s" % last_relay_uri)
			print("  Client targeting server key: %s" % server_key)
			var err = client.create_client(server_key, '{"MulticastInterfaces": [], "Listen": []}')
			expect_equal(err, OK, "client create_client")
			err = client.add_yggdrasil_peer(last_relay_uri)
			expect_equal(err, OK, "client add_peer")
			client_mp = SceneMultiplayer.new()
			client_mp.multiplayer_peer = client
			_tree.set_multiplayer(client_mp, ^"/root/TenHopCli")
		)

		test("wait for client connection (60s timeout)", func():
			var server_key = server.get_yggdrasil_public_key()
			var start = Time.get_ticks_msec()
			var deadline = start + 60000
			var last_log = start
			while client.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
				if Time.get_ticks_msec() > deadline:
					print("  TIMEOUT after 60s")
					print("  Client status: %d" % client.get_connection_status())
					print("  Client tree_entries: %d" % client.get_tree_entries())
					print("  Client routing_entries: %d" % client.get_routing_entries())
					print("  Client has_route(server): %s" % client.has_route(server_key))
					print("  Server tree_entries: %d" % server.get_tree_entries())
					for i in relays.size():
						print("    relay %d: tree=%d" % [i, relays[i].get_tree_entries()])
					fail("client connection timeout after 60s")
					return
				_poll_all()
				if Time.get_ticks_msec() - last_log > 5000:
					var elapsed = (Time.get_ticks_msec() - start) / 1000.0
					print("  [%.0fs] status=%d, tree=%d, routing=%d, has_route=%s" % [
						elapsed, client.get_connection_status(),
						client.get_tree_entries(), client.get_routing_entries(),
						client.has_route(server_key)])
					last_log = Time.get_ticks_msec()
				await _tree.process_frame
			var elapsed = Time.get_ticks_msec() - start
			print("  Client connected as peer #%d in %dms" % [client.get_unique_id(), elapsed])
			expect_true(true, "client connected")
		)

		test("echo 10 pings through %d hops" % NUM_HOPS, func():
			var echo_cb = func(sender_id, pkt):
				server_mp.send_bytes(pkt, sender_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			server_mp.peer_packet.connect(echo_cb)

			var payload = PackedByteArray()
			payload.resize(64)
			for i in 64:
				payload[i] = (i * 7) % 256

			var success_count = 0
			for ping_i in 10:
				var state = {"got_reply": false}
				var cb = func(_id, _pkt): state["got_reply"] = true
				client_mp.peer_packet.connect(cb)
				var t0 = Time.get_ticks_msec()
				client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
				var ping_deadline = Time.get_ticks_msec() + 5000
				while not state["got_reply"] and Time.get_ticks_msec() < ping_deadline:
					_poll_all()
					await _tree.process_frame
				client_mp.peer_packet.disconnect(cb)
				if state["got_reply"]:
					var rtt = Time.get_ticks_msec() - t0
					print("  Ping %d: %dms RTT" % [ping_i, rtt])
					success_count += 1
				else:
					print("  Ping %d: TIMEOUT (5s)" % ping_i)

			server_mp.peer_packet.disconnect(echo_cb)
			print("  Result: %d/10 pings succeeded" % success_count)
			expect_true(success_count >= 8, "at least 8/10 pings should succeed")
		)
	)

	define("teardown", func():
		test("cleanup", func():
			if client_mp:
				client_mp.multiplayer_peer = null
			if server_mp:
				server_mp.multiplayer_peer = null
			if client:
				client.close()
				client = null
			for relay in relays:
				relay.close()
			relays.clear()
			relay_uris.clear()
			if server:
				server.close()
				server = null
			var srv = _tree.root.get_node_or_null("TenHopSrv")
			if srv: srv.queue_free()
			var cli = _tree.root.get_node_or_null("TenHopCli")
			if cli: cli.queue_free()
			expect_true(true, "cleanup complete")
		)
	)
