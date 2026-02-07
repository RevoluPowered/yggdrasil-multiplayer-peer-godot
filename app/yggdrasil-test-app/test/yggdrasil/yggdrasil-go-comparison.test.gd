extends VestTest
## Mirrors Go lib_test.go TestThroughput and TestLatency (1-hop) for direct comparison.
## Run alongside `go test -run TestThroughput -v` and `go test -run TestLatency -v`
## to compare raw Go performance vs Godot GDExtension + SceneMultiplayer overhead.

const YGG_CONFIG := '{
	"MulticastInterfaces": [
		{"Regex": ".*", "Beacon": true, "Listen": true, "Port": 0, "Priority": 0}
	]
}'

const YGG_CLIENT_CONFIG := '{
	"MulticastInterfaces": [
		{"Regex": ".*", "Beacon": false, "Listen": true, "Port": 0, "Priority": 0}
	]
}'

# --- Match Go test parameters exactly ---
const PACKET_SIZE := 60_000
const THROUGHPUT_SIZES := [
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

# --- Shared state ---
var _tree: SceneTree
var server_peer: YggdrasilPeer
var client_peer: YggdrasilPeer
var server_mp: SceneMultiplayer
var client_mp: SceneMultiplayer
var _server_listen_uri := ""
var _throughput_results: Array = []
var _latency_results: Array = []

func get_suite_name() -> String:
	return "GoComparison"

func before_case(_case_def):
	if not _tree:
		_tree = Vest.get_tree()

func after_all():
	_do_cleanup()

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
			expect_equal(server_peer.create_host(YGG_CONFIG), OK, "create_host")
			_server_listen_uri = server_peer.start_listener("tcp://127.0.0.1:0")
			print("  Server TCP listener: %s" % _server_listen_uri)
			server_mp = SceneMultiplayer.new()
			server_mp.server_relay = true
			server_mp.multiplayer_peer = server_peer
			_tree.set_multiplayer(server_mp, ^"/root/GoCmpSrv")

			client_peer = YggdrasilPeer.new()
			var addr = server_peer.get_yggdrasil_address()
			var cli_cfg = _client_config_with_peer()
			expect_equal(client_peer.create_client(addr, cli_cfg), OK, "create_client")
			client_mp = SceneMultiplayer.new()
			client_mp.multiplayer_peer = client_peer
			_tree.set_multiplayer(client_mp, ^"/root/GoCmpCli")

			await _wait_connected(server_peer)
		)
	)

	# --- Throughput (mirrors Go TestThroughput) ---
	define("throughput (Go comparison)", func():
		test("one-directional streaming, 60KB packets", func():
			for tc in THROUGHPUT_SIZES:
				await _measure_throughput(tc["name"], tc["bytes"])

			# Print summary table matching Go format
			print("")
			print("  Throughput Summary (60KB packets) — Godot side:")
			print("  %-8s %10s" % ["Total", "MB/s"])
			print("  %-8s %10s" % ["-----", "----"])
			for r in _throughput_results:
				print("  %-8s %10.2f" % [r["name"], r["mbps"]])
			print("")
		)
	)

	# --- Latency (mirrors Go TestLatency, 1-hop only) ---
	define("latency (Go comparison)", func():
		test("echo RTT, %d pings, 1 hop" % LATENCY_PINGS, func():
			await _measure_latency()

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
		)
	)

	define("teardown", func():
		test("cleanup", func():
			_do_cleanup()
		)
	)

# ---------------------------------------------------------------
# Throughput
# ---------------------------------------------------------------

func _measure_throughput(label: String, total_bytes: int):
	var state = {"bytes_recv": 0}
	var recv_cb = func(_id, pkt): state["bytes_recv"] += pkt.size()
	server_mp.peer_packet.connect(recv_cb)

	var chunk = _payload(PACKET_SIZE, 0xBE)
	var num_chunks = ceili(float(total_bytes) / PACKET_SIZE)

	print("  %s: sending %d x 60KB chunks..." % [label, num_chunks])

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
	_throughput_results.append({"name": label, "mbps": mbps, "timeout": timed_out})
	if timed_out:
		print("    TIMEOUT: got %d/%d bytes (%.2f MB/s partial)" % [
			state["bytes_recv"], total_bytes, mbps])
	else:
		print("    %s in %.2fs (%.2f MB/s)" % [label, elapsed_sec, mbps])

# ---------------------------------------------------------------
# Latency
# ---------------------------------------------------------------

func _measure_latency():
	# Echo handler on server — mirrors Go echo server
	var echo_cb = func(sender_id, pkt):
		server_mp.send_bytes(pkt, sender_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	server_mp.peer_packet.connect(echo_cb)

	var payload = _payload(LATENCY_PACKET_SIZE, 0xDD)
	var timings := PackedFloat64Array()

	# Warmup: 5 echo round-trips to stabilize
	for i in 5:
		client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		await client_mp.peer_packet

	# Measure RTT
	for i in LATENCY_PINGS:
		var t0 = Time.get_ticks_usec()
		client_mp.send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		await client_mp.peer_packet
		timings.append(float(Time.get_ticks_usec() - t0))

	server_mp.peer_packet.disconnect(echo_cb)

	var stats = _stats(timings)
	_latency_results.append({
		"hops": 1,
		"avg_us": stats["avg_us"],
		"min_us": stats["min_us"],
		"max_us": stats["max_us"],
		"p50_us": stats["p50_us"],
		"p99_us": stats["p99_us"],
	})

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

func _wait_connected(peer: YggdrasilPeer, timeout: float = 10.0):
	var state = {"connected": false}
	peer.peer_connected.connect(func(_id): state["connected"] = true, CONNECT_ONE_SHOT)
	var start = Time.get_ticks_msec()
	var deadline = start + int(timeout * 1000)
	while not state["connected"]:
		if Time.get_ticks_msec() > deadline:
			fail("Connection timeout after %.0fs" % timeout)
			return
		await _tree.process_frame

func _client_config_with_peer(base_config: String = YGG_CLIENT_CONFIG) -> String:
	if _server_listen_uri == "":
		return base_config
	# Insert Peers directly into the JSON string. Avoids JSON round-trip
	# which converts int 0 to float 0.0 (Go rejects 0.0 for uint16 Port).
	var trimmed = base_config.strip_edges()
	var insert_pos = trimmed.rfind("}")
	return trimmed.insert(insert_pos, ',\n\t"Peers": ["%s"]\n' % _server_listen_uri)

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

func _fmt_us(us: float) -> String:
	if us >= 1_000_000: return "%.2fs" % (us / 1_000_000.0)
	elif us >= 1_000: return "%.2fms" % (us / 1_000.0)
	else: return "%.0fus" % us

func _do_cleanup():
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
