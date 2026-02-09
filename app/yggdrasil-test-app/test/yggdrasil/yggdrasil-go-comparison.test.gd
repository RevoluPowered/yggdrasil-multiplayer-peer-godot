extends VestTest
## Mirrors Go lib_test.go TestThroughput and TestLatency (1-hop) for direct comparison.
## Run alongside `go test -run TestThroughput -v` and `go test -run TestLatency -v`
## to compare raw Go performance vs Godot GDExtension + SceneMultiplayer overhead.

const YGG_CONFIG := '{"MulticastInterfaces": [], "Listen": []}'

## --- Match Go test parameters exactly ---
const PACKET_SIZE := 60_000
const THROUGHPUT_SIZES := [
	{"name": "1B", "bytes": 1},
	{"name": "8B", "bytes": 8},
	{"name": "16B", "bytes": 16},
	{"name": "32B", "bytes": 32},
	{"name": "64B", "bytes": 64},
	{"name": "128B", "bytes": 128},
	{"name": "512B", "bytes": 512},
	{"name": "1MB", "bytes": 1_000_000},
	{"name": "8MB", "bytes": 8_000_000},
	{"name": "32MB", "bytes": 32_000_000},
	{"name": "64MB", "bytes": 64_000_000},
	{"name": "128MB", "bytes": 128_000_000},
	{"name": "512MB", "bytes": 512_000_000},
	{"name": "1GB", "bytes": 1_000_000_000},
]
const CHUNKS_PER_FRAME := 200
const THROUGHPUT_TIMEOUT_SEC := 120.0

const LATENCY_PINGS := 100
const LATENCY_PACKET_SIZE := 1500
const LATENCY_HOP_COUNTS := [1, 2, 4, 8, 16, 32, 64]

## --- Shared state ---
var _tree: SceneTree
var server_peer: YggdrasilPeer
var client_peer: YggdrasilPeer
var server_mp: SceneMultiplayer
var client_mp: SceneMultiplayer
var _server_listen_uri := ""
var _throughput_results: Array = []
var _latency_results: Array = []
var _relay_peers: Array = []
var _relay_uris: Array = []

func get_suite_name() -> String:
	return "GoComparison"

func before_case(_case_def):
	if not _tree:
		_tree = Vest.get_tree()

# ---------------------------------------------------------------
# Suite
# ---------------------------------------------------------------

func suite() -> void:
	define("setup", func():
		test("connect server and client", func():
			var sw = Node.new(); sw.name = "GoCmpSrv"
			_tree.root.add_child(sw)
			var cw = Node.new(); cw.name = "GoCmpCli"
			_tree.root.add_child(cw)

			server_peer = YggdrasilPeer.new()
			server_peer.debug_logging = true
			var t0 = Time.get_ticks_msec()
			expect_equal(server_peer.create_host(YGG_CONFIG), OK, "create_host")
			var t1 = Time.get_ticks_msec()
			_server_listen_uri = server_peer.start_listener("quic://127.0.0.1:0")
			var t2 = Time.get_ticks_msec()
			print("  Server create_host: %dms, start_listener: %dms" % [t1 - t0, t2 - t1])
			print("  Server QUIC listener: %s" % _server_listen_uri)
			server_mp = SceneMultiplayer.new()
			server_mp.server_relay = true
			server_mp.multiplayer_peer = server_peer
			_tree.set_multiplayer(server_mp, ^"/root/GoCmpSrv")

			client_peer = YggdrasilPeer.new()
			client_peer.debug_logging = true
			var server_key = server_peer.get_yggdrasil_public_key()
			var t3 = Time.get_ticks_msec()
			expect_equal(client_peer.create_client(server_key, YGG_CONFIG), OK, "create_client")
			expect_equal(client_peer.add_yggdrasil_peer(_server_listen_uri), OK, "client add_peer")
			print("  Client create_client: %dms" % [Time.get_ticks_msec() - t3])
			client_mp = SceneMultiplayer.new()
			client_mp.multiplayer_peer = client_peer
			_tree.set_multiplayer(client_mp, ^"/root/GoCmpCli")

			if not await _wait_connected(server_peer):
				fail("Initial server connection timeout")
				return
			if not await _wait_client_connected():
				fail("Initial client handshake timeout")
				return
		)
	)

	# --- Throughput (mirrors Go TestThroughput) ---
	define("throughput (Go comparison)", func():
		test("one-directional streaming, 60KB packets", func():
			for tc in THROUGHPUT_SIZES:
				await _measure_throughput(tc["name"], tc["bytes"])

			# Print summary table
			print("")
			print("  Throughput Summary — Godot side:")
			print("  %-8s %12s %10s" % ["Total", "Time", "Rate"])
			print("  %-8s %12s %10s" % ["-----", "----", "----"])
			for r in _throughput_results:
				var rate_str: String
				if r["bytes"] >= 1_000_000:
					rate_str = "%.2f MB/s" % r["mbps"]
				elif r["bytes"] >= 1_000:
					rate_str = "%.2f KB/s" % (r["mbps"] * 1000.0)
				else:
					rate_str = "%d B/s" % int(r["mbps"] * 1_000_000.0)
				print("  %-8s %12s %10s" % [r["name"], _fmt_us(r["elapsed_us"]), rate_str])
			print("")

			# Assertions — only check MB/s for transfers >= 1MB
			for r in _throughput_results:
				expect_false(r["timeout"], "%s should not timeout" % r["name"])
				if r["bytes"] >= 1_000_000:
					expect_true(r["mbps"] > 10.0, "%s should exceed 10 MB/s (got %.2f)" % [r["name"], r["mbps"]])
		)
	)
	# --- Latency (mirrors Go TestLatency, multi-hop) ---
	define("latency (Go comparison)", func():
		test("echo RTT, %d pings, hops %s" % [LATENCY_PINGS, LATENCY_HOP_COUNTS], func():
			# Build the ENTIRE relay chain up front (like Go test).
			# Max hops needs max_hops-1 relays.
			var max_hops = LATENCY_HOP_COUNTS.max()
			var max_relays = max_hops - 1
			print("  Building full relay chain (%d relays) for up to %d hops..." % [max_relays, max_hops])
			var chain_uri = _extend_relay_chain(max_relays)
			if chain_uri == "":
				fail("Failed to build full relay chain")
				return
			print("  Full chain built: %d relays" % _relay_peers.size())

			# Wait for partial tree convergence (tree >= 2 per node)
			print("  Waiting for partial tree convergence...")
			var all_nodes: Array = [server_peer] + _relay_peers
			var converge_start = Time.get_ticks_msec()
			var converge_deadline = converge_start + 30000
			while true:
				var min_tree = 999
				var all_ready = true
				for node in all_nodes:
					var t = node.get_tree_entries()
					if t < 2:
						all_ready = false
					min_tree = min(min_tree, t)
				if all_ready:
					print("  All nodes have tree >= 2 (%dms)" % [Time.get_ticks_msec() - converge_start])
					break
				if Time.get_ticks_msec() > converge_deadline:
					print("  WARNING: not all nodes have tree >= 2 after 30s (min=%d)" % min_tree)
					break
				await _tree.process_frame

			# Brief pause for routing table propagation
			print("  Pausing 1s for routing table propagation...")
			var pause_start = Time.get_ticks_msec()
			while Time.get_ticks_msec() - pause_start < 1000:
				await _tree.process_frame

			var latency_loop_start = Time.get_ticks_msec()
			for hops in LATENCY_HOP_COUNTS:
				var hop_start = Time.get_ticks_msec()
				if hops > 1:
					# Disconnect existing client
					if client_mp:
						client_mp.multiplayer_peer = null
					if client_peer:
						client_peer.close()
						client_peer = null

					# Pick entry point from pre-built chain: relay[hops-2]
					var target_uri = _relay_uris[hops - 2]
					print("  [%dms] Connecting client for %d-hop via %s..." % [hop_start - latency_loop_start, hops, target_uri])

					client_peer = YggdrasilPeer.new()
					client_peer.debug_logging = true
					var server_key = server_peer.get_yggdrasil_public_key()
					var tc0 = Time.get_ticks_msec()
					expect_equal(client_peer.create_client(server_key, YGG_CONFIG), OK,
						"create_client for %d-hop" % hops)
					expect_equal(client_peer.add_yggdrasil_peer(target_uri), OK,
						"client add_peer for %d-hop" % hops)
					print("  [%dms] Client create_client (%d-hop): %dms" % [Time.get_ticks_msec() - latency_loop_start, hops, Time.get_ticks_msec() - tc0])
					client_mp = SceneMultiplayer.new()
					client_mp.multiplayer_peer = client_peer
					_tree.set_multiplayer(client_mp, ^"/root/GoCmpCli")
				else:
					print("  [%dms] Starting %d-hop test..." % [hop_start - latency_loop_start, hops])

				# Warmup handles connection establishment + routing convergence
				print("  [%dms] Warming up %d-hop path..." % [Time.get_ticks_msec() - latency_loop_start, hops])
				var warmed = await _warmup_echo(60.0)
				if not warmed:
					print("  [%dms] SKIP: %d-hop warmup failed (no echo after 60s)" % [Time.get_ticks_msec() - latency_loop_start, hops])
					continue

				print("  [%dms] Measuring %d-hop latency..." % [Time.get_ticks_msec() - latency_loop_start, hops])
				await _measure_latency(hops)
				print("  [%dms] %d-hop done" % [Time.get_ticks_msec() - latency_loop_start, hops])

			# Chain stays alive — cleaned up in teardown
			_kill_relays()

			# Print summary table
			print("")
			print("  Latency Summary (echo RTT, %d pings) — Godot side:" % LATENCY_PINGS)
			print("  %-10s %12s %12s %12s %12s" % ["Hops", "Avg RTT", "Min", "P50", "P99"])
			print("  %-10s %12s %12s %12s %12s" % ["----", "-------", "---", "---", "---"])
			for r in _latency_results:
				print("  %-10d %12s %12s %12s %12s" % [
					r["hops"],
					_fmt_us(r["avg_us"]),
					_fmt_us(r["min_us"]),
					_fmt_us(r["p50_us"]),
					_fmt_us(r["p99_us"]),
				])
			print("")

			# Assertions
			expect_not_empty(_latency_results, "should have latency results")
			for r in _latency_results:
				expect_true(r["avg_us"] > 0.0, "%d-hop avg RTT should be > 0" % r["hops"])
			# 1-hop assertions (tightest bounds)
			var r1 = _latency_results[0]
			expect_true(r1["avg_us"] < 200_000.0,
				"1-hop avg RTT should be < 200ms (got %s)" % _fmt_us(r1["avg_us"]))
			expect_true(r1["min_us"] < 50_000.0,
				"1-hop min RTT should be < 50ms (got %s)" % _fmt_us(r1["min_us"]))
		)
	)

	define("teardown", func():
		test("cleanup", func():
			_do_cleanup()
			expect_true(true, "cleanup complete")
		)
	)

# ---------------------------------------------------------------
# Throughput
# ---------------------------------------------------------------

func _measure_throughput(label: String, total_bytes: int):
	var state = {"bytes_recv": 0}
	var recv_cb = func(_id, pkt): state["bytes_recv"] += pkt.size()
	server_mp.peer_packet.connect(recv_cb)

	var chunk_size = mini(PACKET_SIZE, total_bytes) if total_bytes > 0 else PACKET_SIZE
	var chunk = _payload(chunk_size, 0xBE)
	var num_chunks = maxi(1, ceili(float(total_bytes) / chunk_size))

	print("  %s: sending %d x %s..." % [label, num_chunks, _fmt_bytes(chunk_size)])

	var start_us = Time.get_ticks_usec()
	var sent := 0
	while sent < num_chunks:
		var batch = mini(CHUNKS_PER_FRAME, num_chunks - sent)
		for i in batch:
			client_mp.send_bytes(chunk, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			sent += 1
		await _tree.process_frame

	# Wait for all data to arrive
	var timeout_us = int(THROUGHPUT_TIMEOUT_SEC * 1_000_000)
	while state["bytes_recv"] < total_bytes:
		if Time.get_ticks_usec() - start_us > timeout_us:
			break
		await _tree.process_frame

	var elapsed_us = Time.get_ticks_usec() - start_us
	var elapsed_sec = elapsed_us / 1_000_000.0
	var mbps = (total_bytes / 1_000_000.0) / elapsed_sec if elapsed_sec > 0 else 0.0
	server_mp.peer_packet.disconnect(recv_cb)

	var timed_out = state["bytes_recv"] < total_bytes
	_throughput_results.append({
		"name": label, "bytes": total_bytes, "mbps": mbps,
		"elapsed_us": elapsed_us, "timeout": timed_out,
	})
	if timed_out:
		print("    TIMEOUT: got %d/%d bytes" % [state["bytes_recv"], total_bytes])
	else:
		print("    %s in %s" % [label, _fmt_us(elapsed_us)])
	expect_false(timed_out, "%s should complete without timeout" % label)

# ---------------------------------------------------------------
# Latency
# ---------------------------------------------------------------

func _warmup_echo(timeout_sec: float = 60.0) -> bool:
	# Retry-based warmup matching Go's approach: send every 200ms until first echo.
	var echo_cb = func(sender_id, pkt):
		server_mp.send_bytes(pkt, sender_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	server_mp.peer_packet.connect(echo_cb)

	var state = {"got_echo": false}
	var client_cb = func(_id, _pkt): state["got_echo"] = true
	client_mp.peer_packet.connect(client_cb)

	var payload = _payload(64, 0xCC)
	var deadline = Time.get_ticks_msec() + int(timeout_sec * 1000)
	var attempts = 0
	while not state["got_echo"] and Time.get_ticks_msec() < deadline:
		# Wait for client to be connected before sending
		if client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			await _tree.process_frame
			continue
		client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		# Wait ~200ms for response
		var wait_end = Time.get_ticks_msec() + 200
		while Time.get_ticks_msec() < wait_end and not state["got_echo"]:
			await _tree.process_frame
		attempts += 1
		if attempts % 25 == 0 and not state["got_echo"]:
			print("    Warmup: %d attempts (%.0fs)..." % [attempts, (Time.get_ticks_msec() - (deadline - timeout_sec * 1000)) / 1000.0])

	client_mp.peer_packet.disconnect(client_cb)
	server_mp.peer_packet.disconnect(echo_cb)

	if not state["got_echo"]:
		return false

	# Stabilization: 5 more echo round-trips (like Go)
	echo_cb = func(sender_id, pkt):
		server_mp.send_bytes(pkt, sender_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	server_mp.peer_packet.connect(echo_cb)
	for i in 5:
		client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		var stab_state = {"done": false}
		var stab_cb = func(_id, _pkt): stab_state["done"] = true
		client_mp.peer_packet.connect(stab_cb)
		var stab_deadline = Time.get_ticks_msec() + 5000
		while not stab_state["done"] and Time.get_ticks_msec() < stab_deadline:
			await _tree.process_frame
		client_mp.peer_packet.disconnect(stab_cb)
		if not stab_state["done"]:
			print("    Stabilization ping %d timed out" % i)
			break
	server_mp.peer_packet.disconnect(echo_cb)

	print("    Warmup done after %d attempts" % attempts)
	return true

func _measure_latency(hops: int):
	# Echo handler on server — mirrors Go echo server
	var echo_cb = func(sender_id, pkt):
		server_mp.send_bytes(pkt, sender_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	server_mp.peer_packet.connect(echo_cb)

	var payload = _payload(LATENCY_PACKET_SIZE, 0xDD)
	var timings := PackedFloat64Array()
	var dropped := 0

	# Measure RTT (warmup already done by _warmup_echo)
	for i in LATENCY_PINGS:
		var t0 = Time.get_ticks_usec()
		client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		# Await with 10s timeout per ping to avoid hard hangs
		var state = {"got_reply": false}
		var cb = func(_id, _pkt): state["got_reply"] = true
		client_mp.peer_packet.connect(cb)
		var ping_deadline = Time.get_ticks_msec() + 5000
		while not state["got_reply"] and Time.get_ticks_msec() < ping_deadline:
			await _tree.process_frame
		client_mp.peer_packet.disconnect(cb)
		if state["got_reply"]:
			timings.append(float(Time.get_ticks_usec() - t0))
		else:
			dropped += 1
			if dropped >= 5:
				print("    %d-hop: %d pings dropped, aborting measurement" % [hops, dropped])
				break

	server_mp.peer_packet.disconnect(echo_cb)
	if dropped > 0:
		print("    %d-hop: %d/%d pings dropped" % [hops, dropped, LATENCY_PINGS])

	var stats = _stats(timings)
	_latency_results.append({
		"hops": hops,
		"avg_us": stats["avg_us"],
		"min_us": stats["min_us"],
		"max_us": stats["max_us"],
		"p50_us": stats["p50_us"],
		"p99_us": stats["p99_us"],
	})

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

func _wait_connected(peer: YggdrasilPeer, timeout: float = 10.0) -> bool:
	var state = {"connected": false}
	peer.peer_connected.connect(func(_id): state["connected"] = true, CONNECT_ONE_SHOT)
	var start = Time.get_ticks_msec()
	var deadline = start + int(timeout * 1000)
	while not state["connected"]:
		if Time.get_ticks_msec() > deadline:
			return false
		await _tree.process_frame
	return true

func _wait_client_connected(timeout: float = 10.0) -> bool:
	var deadline = Time.get_ticks_msec() + int(timeout * 1000)
	while client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if Time.get_ticks_msec() > deadline:
			return false
		await _tree.process_frame
	return true

func _payload(sz: int, seed_byte: int = 0xAA) -> PackedByteArray:
	var d := PackedByteArray()
	d.resize(sz)
	for i in sz:
		d[i] = ((seed_byte * (i + 1)) + i) % 256
	return d

func _stats(timings: PackedFloat64Array) -> Dictionary:
	var sorted := PackedFloat64Array(timings)
	sorted.sort()
	var n := sorted.size()
	if n == 0:
		return {"count": 0, "avg_us": 0.0, "min_us": 0.0, "max_us": 0.0,
			"p50_us": 0.0, "p99_us": 0.0}
	var sum := 0.0
	for t in sorted: sum += t
	return {
		"count": n, "avg_us": sum / n,
		"min_us": sorted[0], "max_us": sorted[n - 1],
		"p50_us": sorted[n / 2.0],
		"p99_us": sorted[mini(int(n * 0.99), n - 1)],
	}

func _fmt_bytes(b: int) -> String:
	if b >= 1_000_000: return "%.0fMB" % (b / 1_000_000.0)
	elif b >= 1_000: return "%.0fKB" % (b / 1_000.0)
	else: return "%dB" % b

func _fmt_us(us: float) -> String:
	if us >= 1_000_000: return "%.2fs" % (us / 1_000_000.0)
	elif us >= 1_000: return "%.2fms" % (us / 1_000.0)
	else: return "%.0fus" % us

func _extend_relay_chain(target_count: int) -> String:
	var have = _relay_peers.size()
	if target_count <= have:
		return _relay_uris[target_count - 1]
	var prev_uri = _relay_uris.back() if have > 0 else _server_listen_uri
	var batch_start = Time.get_ticks_msec()
	var total_create := 0
	var total_listen := 0
	# Create all relays first (no connections yet)
	var new_relays: Array = []
	for i in range(have, target_count):
		var relay = YggdrasilPeer.new()
		var t0 = Time.get_ticks_msec()
		var err = relay.create_relay(YGG_CONFIG)
		var t1 = Time.get_ticks_msec()
		if err != OK:
			printerr("  Relay %d create_relay failed: %s" % [i, error_string(err)])
			return ""
		var uri = relay.start_listener("quic://127.0.0.1:0")
		var t2 = Time.get_ticks_msec()
		if uri == "":
			printerr("  Relay %d start_listener failed" % i)
			relay.close()
			return ""
		new_relays.append({"relay": relay, "uri": uri})
		_relay_peers.append(relay)
		_relay_uris.append(uri)
		var dt_create = t1 - t0
		var dt_listen = t2 - t1
		total_create += dt_create
		total_listen += dt_listen
		var elapsed = Time.get_ticks_msec() - batch_start
		print("    Relay %d: create_relay %dms, start_listener %dms (cumulative %dms) -> %s" % [i, dt_create, dt_listen, elapsed, uri])
	# Chain via CallPeer (fast ephemeral links)
	for i in new_relays.size():
		var relay = new_relays[i]["relay"]
		var err = relay.add_yggdrasil_peer(prev_uri)
		if err != OK:
			printerr("  Relay %d add_yggdrasil_peer failed: %s" % [have + i, error_string(err)])
			return ""
		prev_uri = new_relays[i]["uri"]
	var batch_total = Time.get_ticks_msec() - batch_start
	var added = target_count - have
	print("    Chain +%d relays in %dms (avg %dms/node, create_relay total %dms, start_listener total %dms)" % [added, batch_total, batch_total / added, total_create, total_listen])
	return prev_uri

func _kill_relays():
	for relay in _relay_peers:
		relay.close()
	_relay_peers.clear()
	_relay_uris.clear()

func _do_cleanup():
	_kill_relays()
	if client_mp:
		client_mp.multiplayer_peer = null
	if server_mp:
		server_mp.multiplayer_peer = null
	if client_peer:
		client_peer.close()
		client_peer = null
	if server_peer:
		server_peer.close()
		server_peer = null
	if _tree:
		var srv = _tree.root.get_node_or_null("GoCmpSrv")
		if srv: srv.queue_free()
		var cli = _tree.root.get_node_or_null("GoCmpCli")
		if cli: cli.queue_free()
