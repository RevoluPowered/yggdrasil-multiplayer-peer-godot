extends VestTest
## Compares raw ygg C API performance vs MultiplayerPeer+SceneMultiplayer.
## Proves whether slowness is in yggdrasil or in Godot's frame-aligned polling.
##
## Raw C API: send_raw/recv_raw call ygg_send_to/ygg_recv_from_timeout directly.
## These BLOCK the main thread — fine for benchmarks, not for gameplay.
##
## MultiplayerPeer: same packets but routed through _put_packet → _poll → signal.
## Each send/recv costs at least 1 frame (~16ms at 60fps) due to poll() alignment.

var _tree: SceneTree

# Raw C API nodes (bare — no recv threads, no protocol)
var raw_a: YggdrasilPeer
var raw_b: YggdrasilPeer
var raw_a_key: String
var raw_b_key: String

# MultiplayerPeer nodes (full protocol)
var mp_server: YggdrasilPeer
var mp_client: YggdrasilPeer
var mp_server_mp: SceneMultiplayer
var mp_client_mp: SceneMultiplayer
var _server_listen_uri := ""

const LATENCY_PINGS := 100
const LATENCY_PACKET_SIZE := 1500
const THROUGHPUT_PACKETS := 1000
const THROUGHPUT_SIZES := [64, 1500, 60000]
const WARMUP_TIMEOUT_SEC := 30.0

func get_suite_name() -> String:
	return "RawVsMultiplayerPeer"

func before_case(_case_def):
	if not _tree:
		_tree = Vest.get_tree()

# ---------------------------------------------------------------
# Suite
# ---------------------------------------------------------------

func suite() -> void:
	# --- Setup raw C API nodes ---
	define("setup raw nodes", func():
		test("create two bare nodes connected via QUIC", func():
			raw_a = YggdrasilPeer.new()
			var err_a = raw_a.create_bare('{"MulticastInterfaces": [], "Listen": []}')
			expect_equal(err_a, OK, "raw_a create_bare")
			raw_a_key = raw_a.get_yggdrasil_public_key()
			var uri_a = raw_a.start_listener("quic://127.0.0.1:0")
			expect_not_empty(uri_a, "raw_a listener")
			print("  Raw A key: %s" % raw_a_key)
			print("  Raw A listener: %s" % uri_a)

			raw_b = YggdrasilPeer.new()
			var err_b = raw_b.create_bare('{"MulticastInterfaces": [], "Peers": ["%s"], "Listen": []}' % uri_a)
			expect_equal(err_b, OK, "raw_b create_bare")
			raw_b_key = raw_b.get_yggdrasil_public_key()
			print("  Raw B key: %s" % raw_b_key)

			# Wait for routing to converge by sending warmup pings
			print("  Warming up raw path...")
			var warmup_payload = PackedByteArray()
			warmup_payload.resize(8)
			for i in 8: warmup_payload[i] = 0xAA

			var warmup_start = Time.get_ticks_msec()
			var warmed = false
			while Time.get_ticks_msec() - warmup_start < WARMUP_TIMEOUT_SEC * 1000:
				raw_a.send_raw(raw_b_key, warmup_payload)
				var r = raw_b.recv_raw(200)  # 200ms timeout per attempt
				if r.size() > 0:
					warmed = true
					break
			var warmup_ms = Time.get_ticks_msec() - warmup_start
			expect_true(warmed, "raw warmup should succeed within %ds" % WARMUP_TIMEOUT_SEC)
			print("  Raw warmup done in %dms" % warmup_ms)

			# Drain any extra warmup packets
			while true:
				var drain = raw_b.recv_raw(50)
				if drain.size() == 0:
					break
			while true:
				var drain = raw_a.recv_raw(50)
				if drain.size() == 0:
					break
		)
	)

	# --- Raw C API benchmarks ---
	define("raw C API benchmarks", func():
		test("echo RTT (%d pings, %dB)" % [LATENCY_PINGS, LATENCY_PACKET_SIZE], func():
			var payload = _make_payload(LATENCY_PACKET_SIZE, 0xDD)
			var timings := PackedFloat64Array()

			for i in LATENCY_PINGS:
				var t0 = Time.get_ticks_usec()
				# A → B
				raw_a.send_raw(raw_b_key, payload)
				var r1 = raw_b.recv_raw(5000)
				if r1.size() == 0:
					print("    Ping %d: recv on B timed out" % i)
					continue
				# B → A (echo)
				raw_b.send_raw(raw_a_key, r1["data"])
				var r2 = raw_a.recv_raw(5000)
				if r2.size() == 0:
					print("    Ping %d: echo recv on A timed out" % i)
					continue
				timings.append(float(Time.get_ticks_usec() - t0))

			var stats = _stats(timings)
			print("  RAW echo RTT (%d pings):" % timings.size())
			print("    avg=%s  min=%s  p50=%s  p99=%s  max=%s" % [
				_fmt_us(stats["avg_us"]), _fmt_us(stats["min_us"]),
				_fmt_us(stats["p50_us"]), _fmt_us(stats["p99_us"]),
				_fmt_us(stats["max_us"])])
			expect_true(timings.size() >= LATENCY_PINGS * 0.9,
				"at least 90%% of pings should succeed")
		)

		test("one-way throughput across sizes", func():
			for sz in THROUGHPUT_SIZES:
				var payload = _make_payload(sz, 0xBE)
				var t0 = Time.get_ticks_usec()

				# Send all packets (non-blocking, queues in Go)
				for i in THROUGHPUT_PACKETS:
					raw_a.send_raw(raw_b_key, payload)

				# Recv all packets (blocking per-packet, but data is buffered)
				var recv_count := 0
				for i in THROUGHPUT_PACKETS:
					var r = raw_b.recv_raw(10000)
					if r.size() == 0:
						break
					recv_count += 1

				var elapsed_us = Time.get_ticks_usec() - t0
				var elapsed_sec = elapsed_us / 1_000_000.0
				var total_bytes = recv_count * sz
				var mbps = (total_bytes / 1_000_000.0) / elapsed_sec if elapsed_sec > 0 else 0.0
				print("  RAW throughput %s: %d/%d pkts in %s (%.2f MB/s)" % [
					_fmt_bytes(sz), recv_count, THROUGHPUT_PACKETS,
					_fmt_us(float(elapsed_us)), mbps])

				# Drain any remaining
				while true:
					var drain = raw_b.recv_raw(50)
					if drain.size() == 0: break
		)
	)

	# --- Setup MultiplayerPeer nodes ---
	define("setup MultiplayerPeer nodes", func():
		test("create host + client on same QUIC link", func():
			var sw = Node.new(); sw.name = "RawVsMpSrv"
			_tree.root.add_child(sw)
			var cw = Node.new(); cw.name = "RawVsMpCli"
			_tree.root.add_child(cw)

			mp_server = YggdrasilPeer.new()
			var err = mp_server.create_host('{"MulticastInterfaces": [], "Listen": []}')
			expect_equal(err, OK, "mp_server create_host")
			_server_listen_uri = mp_server.start_listener("quic://127.0.0.1:0")
			print("  MP Server listener: %s" % _server_listen_uri)
			mp_server_mp = SceneMultiplayer.new()
			mp_server_mp.server_relay = true
			mp_server_mp.multiplayer_peer = mp_server
			_tree.set_multiplayer(mp_server_mp, ^"/root/RawVsMpSrv")

			mp_client = YggdrasilPeer.new()
			var server_key = mp_server.get_yggdrasil_public_key()
			var cli_cfg = '{"MulticastInterfaces": [], "Peers": ["%s"], "Listen": []}' % _server_listen_uri
			err = mp_client.create_client(server_key, cli_cfg)
			expect_equal(err, OK, "mp_client create_client")
			mp_client_mp = SceneMultiplayer.new()
			mp_client_mp.multiplayer_peer = mp_client
			_tree.set_multiplayer(mp_client_mp, ^"/root/RawVsMpCli")

			# Wait for connection
			var state = {"connected": false}
			mp_server.peer_connected.connect(func(_id): state["connected"] = true, CONNECT_ONE_SHOT)
			var start = Time.get_ticks_msec()
			var deadline = start + 15000
			while not state["connected"]:
				if Time.get_ticks_msec() > deadline:
					fail("MP connection timeout (15s)")
					return
				await _tree.process_frame
			print("  MP connected in %dms" % [Time.get_ticks_msec() - start])
		)
	)

	# --- MultiplayerPeer benchmarks (frame-aligned await) ---
	define("MultiplayerPeer benchmarks (await)", func():
		test("echo RTT with await (%d pings, %dB)" % [LATENCY_PINGS, LATENCY_PACKET_SIZE], func():
			# Server echoes everything back
			var echo_cb = func(sender_id, pkt):
				mp_server_mp.send_bytes(pkt, sender_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			mp_server_mp.peer_packet.connect(echo_cb)

			var payload = _make_payload(LATENCY_PACKET_SIZE, 0xDD)
			var timings := PackedFloat64Array()

			for i in LATENCY_PINGS:
				var t0 = Time.get_ticks_usec()
				mp_client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
				var state = {"got_reply": false}
				var cb = func(_id, _pkt): state["got_reply"] = true
				mp_client_mp.peer_packet.connect(cb)
				var deadline = Time.get_ticks_msec() + 5000
				while not state["got_reply"] and Time.get_ticks_msec() < deadline:
					await _tree.process_frame
				mp_client_mp.peer_packet.disconnect(cb)
				if state["got_reply"]:
					timings.append(float(Time.get_ticks_usec() - t0))

			mp_server_mp.peer_packet.disconnect(echo_cb)

			var stats = _stats(timings)
			print("  MP (await) echo RTT (%d pings):" % timings.size())
			print("    avg=%s  min=%s  p50=%s  p99=%s  max=%s" % [
				_fmt_us(stats["avg_us"]), _fmt_us(stats["min_us"]),
				_fmt_us(stats["p50_us"]), _fmt_us(stats["p99_us"]),
				_fmt_us(stats["max_us"])])
		)
	)

	# --- MultiplayerPeer benchmarks (manual tight poll) ---
	define("MultiplayerPeer benchmarks (manual poll)", func():
		test("echo RTT with tight poll (%d pings, %dB)" % [LATENCY_PINGS, LATENCY_PACKET_SIZE], func():
			var echo_cb = func(sender_id, pkt):
				mp_server_mp.send_bytes(pkt, sender_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			mp_server_mp.peer_packet.connect(echo_cb)

			var payload = _make_payload(LATENCY_PACKET_SIZE, 0xDD)
			var timings := PackedFloat64Array()

			for i in LATENCY_PINGS:
				var state = {"got_reply": false}
				var cb = func(_id, _pkt): state["got_reply"] = true
				mp_client_mp.peer_packet.connect(cb)

				var t0 = Time.get_ticks_usec()
				mp_client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)

				# Tight poll loop — no frame yields
				var deadline = Time.get_ticks_usec() + 5_000_000
				while not state["got_reply"] and Time.get_ticks_usec() < deadline:
					mp_server_mp.poll()
					mp_client_mp.poll()

				mp_client_mp.peer_packet.disconnect(cb)
				if state["got_reply"]:
					timings.append(float(Time.get_ticks_usec() - t0))

			mp_server_mp.peer_packet.disconnect(echo_cb)

			var stats = _stats(timings)
			print("  MP (tight poll) echo RTT (%d pings):" % timings.size())
			print("    avg=%s  min=%s  p50=%s  p99=%s  max=%s" % [
				_fmt_us(stats["avg_us"]), _fmt_us(stats["min_us"]),
				_fmt_us(stats["p50_us"]), _fmt_us(stats["p99_us"]),
				_fmt_us(stats["max_us"])])
		)
	)

	# --- Teardown ---
	define("teardown", func():
		test("cleanup", func():
			# MP cleanup
			if mp_client_mp:
				mp_client_mp.multiplayer_peer = null
			if mp_server_mp:
				mp_server_mp.multiplayer_peer = null
			if mp_client:
				mp_client.close()
				mp_client = null
			if mp_server:
				mp_server.close()
				mp_server = null
			if _tree:
				var srv = _tree.root.get_node_or_null("RawVsMpSrv")
				if srv: srv.queue_free()
				var cli = _tree.root.get_node_or_null("RawVsMpCli")
				if cli: cli.queue_free()

			# Raw cleanup
			if raw_b:
				raw_b.close()
				raw_b = null
			if raw_a:
				raw_a.close()
				raw_a = null

			expect_true(true, "cleanup complete")
		)
	)

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

func _make_payload(sz: int, seed_byte: int) -> PackedByteArray:
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
		"p50_us": sorted[n / 2],
		"p99_us": sorted[mini(int(n * 0.99), n - 1)],
	}

func _fmt_us(us: float) -> String:
	if us >= 1_000_000: return "%.2fs" % (us / 1_000_000.0)
	elif us >= 1_000: return "%.2fms" % (us / 1_000.0)
	else: return "%.0fus" % us

func _fmt_bytes(b: int) -> String:
	if b >= 1_000_000: return "%.0fMB" % (b / 1_000_000.0)
	elif b >= 1_000: return "%.0fKB" % (b / 1_000.0)
	else: return "%dB" % b
