extends Node
## Standalone test scene: creates server + client YggdrasilPeer in one process.
## Logs every signal, packet event, and state change to pinpoint where data flow breaks.
##
## Run this scene directly from the Godot editor.

const YGG_CONFIG := '{
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

var server_peer: YggdrasilPeer
var client_peer: YggdrasilPeer
var server_mp: SceneMultiplayer
var client_mp: SceneMultiplayer

# Phase tracking:
#   0=setup, 1=waiting_connect, 2=connected_transition, 3=basic_data,
#   4=multi_size, 5=burst, 6=hash_integrity, 7=ordering,
#   8=type_serialize, 9=multi_peer, 10=benchmark, 99=done
var _phase := 0
var _timer := 0.0
var _connect_timeout := 15.0
var _log_packets := false
var _data_test_timer := 0.0

var _server_saw_peer := false
var _client_saw_server := false

# Track signals from SceneMultiplayer (not just the peer)
var _server_mp_peer_connected := false
var _client_mp_peer_connected := false

# --- Phase 3: Basic data test ---
var _basic_server_got_data := false
var _basic_client_got_data := false
var _basic_server_recv: PackedByteArray
var _basic_client_recv: PackedByteArray
var BASIC_CLIENT_PAYLOAD := PackedByteArray([0xDE, 0xAD, 0xBE, 0xEF])
var BASIC_SERVER_PAYLOAD := PackedByteArray([0xCA, 0xFE, 0xBA, 0xBE])

# --- Phase 4: Multi-size packet test ---
var _multi_sizes := [1, 16, 256, 1024, 4096]
var _multi_server_recv: Array[PackedByteArray] = []
var _multi_client_recv: Array[PackedByteArray] = []
var _multi_sent_to_server: Array[PackedByteArray] = []
var _multi_sent_to_client: Array[PackedByteArray] = []
var _multi_send_done := false
var _multi_expect_count := 0

# --- Phase 5: Burst test ---
const BURST_COUNT := 20
var _burst_server_recv: Array[PackedByteArray] = []
var _burst_client_recv: Array[PackedByteArray] = []
var _burst_sent_to_server: Array[PackedByteArray] = []
var _burst_sent_to_client: Array[PackedByteArray] = []
var _burst_send_done := false

# --- Phase 6: Hash integrity test ---
const HASH_PAYLOAD_SIZE := 8192
var _hash_server_recv: PackedByteArray
var _hash_client_recv: PackedByteArray
var _hash_sent_to_server: PackedByteArray
var _hash_sent_to_client: PackedByteArray
var _hash_server_got := false
var _hash_client_got := false

# --- Phase 7: Ordering test (mixed sizes across multiple frames) ---
const ORDER_TOTAL := 50
const ORDER_PER_FRAME := 5
var _order_server_recv: Array[PackedByteArray] = []
var _order_client_recv: Array[PackedByteArray] = []
var _order_sent_to_server: Array[PackedByteArray] = []
var _order_sent_to_client: Array[PackedByteArray] = []
var _order_send_idx := 0

# --- Phase 8: Type serialization test ---
var _type_server_recv: Array[PackedByteArray] = []
var _type_client_recv: Array[PackedByteArray] = []
var _type_sent_to_server: Array = []  # Original Variant values
var _type_sent_to_client: Array = []
var _type_expect_count := 0

# --- Phase 9: Multi-peer test ---
const MULTI_PEER_COUNT := 5
var _mp_clients: Array = []  # Array of { peer, mp, node, connected, recv }
var _mp_server_recv: Array[PackedByteArray] = []
var _mp_all_connected := false
var _mp_broadcast_sent := false
var _mp_clients_sent := false

# --- Phase 10: Benchmark ---
var BENCH_SIZES := [1, 10, 16, 32, 64, 128,
	1_000_000, 16_000_000, 32_000_000, 128_000_000, 256_000_000, 1_000_000_000]
const BENCH_CHUNK_SIZE := 60000       # Max bytes per send_bytes call
const BENCH_CHUNKS_PER_FRAME := 200   # Sends per _process tick
const BENCH_TIMEOUT_SEC := 120.0      # Per-size timeout

var _bench_idx := 0
var _bench_client_peer: YggdrasilPeer
var _bench_client_mp: SceneMultiplayer
var _bench_sub_phase := 0  # 0=connecting, 1=sending, 2=receiving, 3=done
var _bench_start_usec := 0
var _bench_chunk_template: PackedByteArray
var _bench_last_chunk: PackedByteArray
var _bench_num_chunks := 0
var _bench_chunks_sent := 0
var _bench_bytes_recv := 0
var _bench_target_bytes := 0
var _bench_size_timer := 0.0
var _bench_results: Array = []  # Array of {size, time_ms, mbps}

# Shutdown
var _shutdown_timer := -1.0
var _shutdown_exit_code := 0

# Track overall results
var _tests_passed := 0
var _tests_failed := 0

# Diagnostic: track which peers each SceneMultiplayer has registered
var _server_known_peers: Array[int] = []
var _client_known_peers: Array[int] = []
var _bench_known_peers: Array[int] = []
# Per-mp-client known peers: stored in _mp_clients[i]["known_peers"]

# --- Phase 15: Raw peer API verification (uses existing connected peers) ---
var _raw_sub := 0
var _raw_timer := 0.0

# ---------------------------------------------------------------
# Logging
# ---------------------------------------------------------------

var _log_file: FileAccess

func _log(msg: String):
	var ts = "%.3f" % (Time.get_ticks_msec() / 1000.0)
	var line = "[%s] %s" % [ts, msg]
	print(line)
	if _log_file:
		_log_file.store_line(line)
		_log_file.flush()

func _open_log():
	DirAccess.make_dir_recursive_absolute("user://logs")
	var path = "user://logs/ygg_connection_test_pid%d.log" % OS.get_process_id()
	_log_file = FileAccess.open(path, FileAccess.WRITE)
	_log("Log opened: %s" % path)

func _check(condition: bool, desc: String) -> bool:
	if condition:
		_log("  PASS: %s" % desc)
		_tests_passed += 1
	else:
		_log("  FAIL: %s" % desc)
		_tests_failed += 1
	return condition

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

## Generate a deterministic byte array of given size using a seed byte.
func _make_payload(size: int, seed_byte: int = 0xAA) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(size)
	for i in size:
		data[i] = ((seed_byte * (i + 1)) + i) % 256
	return data

## Compute SHA-256 hex digest for a PackedByteArray.
func _sha256_hex(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish().hex_encode()

## Encode a 4-byte big-endian sequence number into a PackedByteArray.
func _encode_seq(seq: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b[0] = (seq >> 24) & 0xFF
	b[1] = (seq >> 16) & 0xFF
	b[2] = (seq >> 8) & 0xFF
	b[3] = seq & 0xFF
	return b

## Decode a 4-byte big-endian sequence number from the start of a PackedByteArray.
func _decode_seq(data: PackedByteArray) -> int:
	return (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3]

## Diagnostic: poll a SceneMultiplayer and catch the !connected_peers error.
## Logs full state when packets are pending from unknown peers.
func _safe_poll(mp: SceneMultiplayer, label: String, known_peers: Array[int]):
	if mp == null:
		return
	var peer = mp.multiplayer_peer
	if peer == null:
		return

	# Poll the peer first (this moves packets and emits signals)
	# We call peer._poll() indirectly via mp.poll(), but we can check state
	# after the underlying peer poll by checking available count change.
	mp.poll()

	# After poll, check if there are still unprocessed packets (shouldn't be)
	var avail_post = peer.get_available_packet_count()
	if avail_post > 0:
		var pkt_peer = peer.get_packet_peer()
		var status = peer.get_connection_status()
		_log("  !!DIAG!! %s: %d leftover packets after poll, next from peer %d, status=%d, known=%s, phase=%d" % [
			label, avail_post, pkt_peer, status, str(known_peers), _phase])

## Diagnostic: send_bytes with pre-send assertion
func _safe_send(mp: SceneMultiplayer, data: PackedByteArray, target: int,
		mode: MultiplayerPeer.TransferMode, label: String, known_peers: Array[int]) -> Error:
	if target != 0 and target != 1:  # 0=broadcast, 1=server (always valid for clients)
		if not known_peers.has(target):
			_log("  !!ASSERT!! %s: send_bytes target=%d NOT in known_peers=%s phase=%d" % [
				label, target, str(known_peers), _phase])
	var peer = mp.multiplayer_peer
	if peer:
		var status = peer.get_connection_status()
		if status != MultiplayerPeer.CONNECTION_CONNECTED:
			_log("  !!ASSERT!! %s: send_bytes but status=%d (not CONNECTED), target=%d, phase=%d" % [
				label, status, target, _phase])
	return mp.send_bytes(data, target, mode)

# ---------------------------------------------------------------
# Setup
# ---------------------------------------------------------------

func _ready():
	_open_log()
	_log("======================================")
	_log("=== YggdrasilPeer Connection Test  ===")
	_log("======================================")

	# Create child nodes for multiplayer paths
	var server_world = Node.new()
	server_world.name = "ServerWorld"
	add_child(server_world)

	var client_world = Node.new()
	client_world.name = "ClientWorld"
	add_child(client_world)

	# --- SERVER ---
	_log("")
	_log("--- Setting up SERVER ---")
	server_peer = YggdrasilPeer.new()
	server_peer.set_debug_logging(true)
	var serr = server_peer.create_host(YGG_CONFIG)
	_log("  create_host() -> %s" % error_string(serr))
	if serr != OK:
		_log("  FATAL: Cannot create host!")
		return
	_log("  Server address: %s" % server_peer.get_yggdrasil_address())
	_log("  Server unique_id: %d" % server_peer.get_unique_id())
	_log("  Server status: %d" % server_peer.get_connection_status())

	_check(serr == OK, "create_host succeeds")
	_check(server_peer.get_unique_id() == 1, "Server has peer_id 1")
	_check(server_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, "Server is CONNECTED immediately")

	# Connect raw peer signals
	server_peer.peer_connected.connect(func(id):
		_log("  [SIGNAL] server_peer.peer_connected(%d)" % id)
		_server_saw_peer = true
	)
	server_peer.peer_disconnected.connect(func(id):
		_log("  [SIGNAL] server_peer.peer_disconnected(%d)" % id)
	)

	# Create SceneMultiplayer for server
	server_mp = SceneMultiplayer.new()
	server_mp.server_relay = true
	server_mp.multiplayer_peer = server_peer
	_log("  Assigned server_peer to server_mp")

	# Connect SceneMultiplayer signals (track known peers for diagnostics)
	server_mp.peer_connected.connect(func(id):
		_log("  [SIGNAL] server_mp.peer_connected(%d) known_before=%s" % [id, str(_server_known_peers)])
		_server_known_peers.append(id)
		_server_mp_peer_connected = true
	)
	server_mp.peer_disconnected.connect(func(id):
		_log("  [SIGNAL] server_mp.peer_disconnected(%d) known_before=%s" % [id, str(_server_known_peers)])
		_server_known_peers.erase(id)
	)
	server_mp.peer_packet.connect(_on_server_packet)

	# Register server multiplayer on its path
	get_tree().set_multiplayer(server_mp, ^"/root/YggConnectionTest/ServerWorld")

	# --- CLIENT ---
	_log("")
	_log("--- Setting up CLIENT ---")
	client_peer = YggdrasilPeer.new()
	client_peer.set_debug_logging(true)
	var server_addr = server_peer.get_yggdrasil_address()
	var cerr = client_peer.create_client(server_addr, YGG_CONFIG)
	_log("  create_client(%s) -> %s" % [server_addr, error_string(cerr)])
	if cerr != OK:
		_log("  FATAL: Cannot create client!")
		return
	_log("  Client address: %s" % client_peer.get_yggdrasil_address())
	_log("  Client unique_id: %d (will be assigned by server)" % client_peer.get_unique_id())
	_log("  Client status: %d (CONNECTING=%d)" % [client_peer.get_connection_status(), MultiplayerPeer.CONNECTION_CONNECTING])

	_check(cerr == OK, "create_client succeeds")
	_check(client_peer.get_unique_id() == 0, "Client peer_id is 0 before assignment")
	_check(client_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING, "Client is CONNECTING")

	# Connect raw peer signals
	client_peer.peer_connected.connect(func(id):
		_log("  [SIGNAL] client_peer.peer_connected(%d)" % id)
		_client_saw_server = true
	)
	client_peer.peer_disconnected.connect(func(id):
		_log("  [SIGNAL] client_peer.peer_disconnected(%d)" % id)
	)

	# Create SceneMultiplayer for client
	client_mp = SceneMultiplayer.new()
	client_mp.multiplayer_peer = client_peer
	_log("  Assigned client_peer to client_mp")

	# Connect SceneMultiplayer signals (track known peers for diagnostics)
	client_mp.peer_connected.connect(func(id):
		_log("  [SIGNAL] client_mp.peer_connected(%d) known_before=%s" % [id, str(_client_known_peers)])
		_client_known_peers.append(id)
		_client_mp_peer_connected = true
	)
	client_mp.peer_disconnected.connect(func(id):
		_log("  [SIGNAL] client_mp.peer_disconnected(%d) known_before=%s" % [id, str(_client_known_peers)])
		_client_known_peers.erase(id)
	)
	client_mp.peer_packet.connect(_on_client_packet)

	# Register client multiplayer on its path
	get_tree().set_multiplayer(client_mp, ^"/root/YggConnectionTest/ClientWorld")

	_log("")
	_log("--- Waiting for connection (timeout=%.0fs) ---" % _connect_timeout)
	_phase = 1

# ---------------------------------------------------------------
# Packet receive callbacks - route based on current phase
# ---------------------------------------------------------------

func _on_server_packet(id: int, packet: PackedByteArray):
	if _log_packets:
		_log("  [RECV] server_mp.peer_packet(from=%d, size=%d, sha256=%s)" % [
			id, packet.size(), _sha256_hex(packet).left(16)])
	match _phase:
		3:
			_basic_server_recv = packet
			_basic_server_got_data = true
		4:
			_multi_server_recv.append(packet)
		5:
			_burst_server_recv.append(packet)
		6:
			_hash_server_recv = packet
			_hash_server_got = true
		7:
			_order_server_recv.append(packet)
		8:
			_type_server_recv.append(packet)
		9:
			_mp_server_recv.append(packet)
		10:
			_bench_bytes_recv += packet.size()

func _on_client_packet(id: int, packet: PackedByteArray):
	if _log_packets:
		_log("  [RECV] client_mp.peer_packet(from=%d, size=%d, sha256=%s)" % [
			id, packet.size(), _sha256_hex(packet).left(16)])
	match _phase:
		3:
			_basic_client_recv = packet
			_basic_client_got_data = true
		4:
			_multi_client_recv.append(packet)
		5:
			_burst_client_recv.append(packet)
		6:
			_hash_client_recv = packet
			_hash_client_got = true
		7:
			_order_client_recv.append(packet)
		8:
			_type_client_recv.append(packet)

# ---------------------------------------------------------------
# Process loop - drive the test phases
# ---------------------------------------------------------------

func _process(delta):
	# Shutdown countdown
	if _shutdown_timer >= 0.0:
		_shutdown_timer -= delta
		if _shutdown_timer <= 0.0:
			get_tree().quit(_shutdown_exit_code)
		return

	# NOTE: Do NOT manually call mp.poll() here!
	# SceneTree auto-polls all multiplayers registered via set_multiplayer().
	# Double-polling causes packets to be processed before peer_connected
	# signals propagate through SceneMultiplayer's internal state.

	match _phase:
		1: _phase_waiting_connect(delta)
		2: _phase_connected_transition(delta)
		15: _phase_raw_api_tests(delta)
		3: _phase_basic_data(delta)
		4: _phase_multi_size(delta)
		5: _phase_burst(delta)
		6: _phase_hash_integrity(delta)
		7: _phase_ordering(delta)
		8: _phase_type_serialize(delta)
		9: _phase_multi_peer(delta)
		10: _phase_benchmark(delta)

# ---------------------------------------------------------------
# Phase 1: Wait for connection
# ---------------------------------------------------------------

func _phase_waiting_connect(delta):
	_timer += delta

	if int(_timer * 2) != int((_timer - delta) * 2):
		var cs = client_peer.get_connection_status() if client_peer else -1
		var ss = server_peer.get_connection_status() if server_peer else -1
		_log("  ... waiting: client_status=%d server_status=%d elapsed=%.1fs" % [cs, ss, _timer])
		_log("    server_saw_peer=%s client_saw_server=%s" % [str(_server_saw_peer), str(_client_saw_server)])
		_log("    server_mp_peer_connected=%s client_mp_peer_connected=%s" % [str(_server_mp_peer_connected), str(_client_mp_peer_connected)])

	if _server_saw_peer and _client_saw_server:
		_log("")
		_log("=== CONNECTION ESTABLISHED (%.1fs) ===" % _timer)
		_log("  Client unique_id: %d" % client_peer.get_unique_id())
		_log("  Client status: %d (CONNECTED=%d)" % [client_peer.get_connection_status(), MultiplayerPeer.CONNECTION_CONNECTED])
		_log("  Server status: %d" % server_peer.get_connection_status())

		_check(client_peer.get_unique_id() > 1, "Client assigned peer_id > 1")
		_check(client_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, "Client is CONNECTED")
		_check(server_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, "Server still CONNECTED")
		_check(_server_mp_peer_connected, "SceneMultiplayer server saw peer_connected")
		_check(_client_mp_peer_connected, "SceneMultiplayer client saw peer_connected")
		_phase = 2
		_timer = 0.0
		return

	if _timer > _connect_timeout:
		_log("")
		_log("=== TIMEOUT waiting for connection! ===")
		_log("  server_saw_peer=%s  client_saw_server=%s" % [str(_server_saw_peer), str(_client_saw_server)])
		_log("  server_mp_peer_connected=%s  client_mp_peer_connected=%s" % [str(_server_mp_peer_connected), str(_client_mp_peer_connected)])
		_finish_test(false, "Connection timeout")

# ---------------------------------------------------------------
# Phase 2: Short delay for SceneMultiplayer to settle
# ---------------------------------------------------------------

func _phase_connected_transition(delta):
	_timer += delta
	if _timer < 0.1:
		return
	# Diagnostic: snapshot peer state before data tests begin
	_log("")
	_log("--- Peer State Snapshot (pre-data-tests) ---")
	_log("  server_peer: status=%d uid=%d" % [server_peer.get_connection_status(), server_peer.get_unique_id()])
	_log("  client_peer: status=%d uid=%d" % [client_peer.get_connection_status(), client_peer.get_unique_id()])
	_log("  server_mp.get_peers() = %s" % str(server_mp.get_peers()))
	_log("  client_mp.get_peers() = %s" % str(client_mp.get_peers()))
	_log("  _server_known_peers = %s" % str(_server_known_peers))
	_log("  _client_known_peers = %s" % str(_client_known_peers))
	_begin_raw_api_tests()

# ---------------------------------------------------------------
# Phase 15: Raw Peer API Unit Tests (no SceneMultiplayer)
# Tests the raw MultiplayerPeer API contract:
#   SceneMultiplayer calls get_packet_peer() BEFORE get_packet().
#   If get_packet_peer() returns 0, SceneMultiplayer logs
#   "!connected_peers.has(sender)" and drops the packet.
# ---------------------------------------------------------------

func _begin_raw_api_tests():
	_log("")
	_log("========================================")
	_log("=== RAW PEER API VERIFICATION        ===")
	_log("========================================")
	_log("  Testing get_packet_peer() via SceneMultiplayer data flow.")
	_log("  If get_packet_peer() returns wrong sender before get_packet(),")
	_log("  SceneMultiplayer will log '!connected_peers.has(sender)' and drop data.")
	_phase = 15
	_raw_sub = 0
	_raw_timer = 0.0

	# Quick sanity: verify existing peers are ready
	var s_status = server_peer.get_connection_status()
	var c_status = client_peer.get_connection_status()
	var c_id = client_peer.get_unique_id()
	_log("  server status=%d, client status=%d, client_id=%d" % [s_status, c_status, c_id])
	_check(s_status == MultiplayerPeer.CONNECTION_CONNECTED, "RAW: server is CONNECTED")
	_check(c_status == MultiplayerPeer.CONNECTION_CONNECTED, "RAW: client is CONNECTED")
	_check(c_id > 1, "RAW: client has assigned peer_id")

	# Verify SceneMultiplayer knows about peers
	var s_peers = server_mp.get_peers()
	var c_peers = client_mp.get_peers()
	_log("  server_mp.get_peers() = %s" % str(s_peers))
	_log("  client_mp.get_peers() = %s" % str(c_peers))
	_check(s_peers.size() > 0, "RAW: server_mp has peers registered")
	_check(c_peers.size() > 0, "RAW: client_mp has peers registered")

	_raw_sub = 1  # Proceed to data verification

func _phase_raw_api_tests(delta):
	_raw_timer += delta

	# Sub 1: Send data from client → server via SceneMultiplayer.
	# The REAL test: SceneMultiplayer.poll() internally calls get_packet_peer()
	# BEFORE get_packet(). If get_packet_peer() returns the wrong value (0),
	# SceneMultiplayer logs the error and drops the packet.
	# With the fix, get_packet_peer() peeks at process_queue.front().
	if _raw_sub == 1:
		_log("")
		_log("--- Verification: SceneMultiplayer data flow ---")
		_log("  This test verifies that get_packet_peer() returns the correct")
		_log("  sender ID so SceneMultiplayer can process packets.")
		_log("")

		# Proceed to the existing comprehensive data test suite
		_log("========================================")
		_log("=== TEST SUITE: Data Send/Recv       ===")
		_log("========================================")
		_begin_basic_data()
		return

# ---------------------------------------------------------------
# Phase 3: Basic bidirectional data with content verification
# ---------------------------------------------------------------

func _begin_basic_data():
	_log("")
	_log("--- Test: Basic bidirectional send/recv ---")
	_phase = 3
	_data_test_timer = 0.0

	var err1 = client_mp.send_bytes(BASIC_CLIENT_PAYLOAD, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	_log("  client -> server send_bytes([0xDEADBEEF], %d bytes): %s" % [BASIC_CLIENT_PAYLOAD.size(), error_string(err1)])
	_check(err1 == OK, "Client send_bytes to server succeeds")

	var client_id = client_peer.get_unique_id()
	var err2 = server_mp.send_bytes(BASIC_SERVER_PAYLOAD, client_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	_log("  server -> client(%d) send_bytes([0xCAFEBABE], %d bytes): %s" % [client_id, BASIC_SERVER_PAYLOAD.size(), error_string(err2)])
	_check(err2 == OK, "Server send_bytes to client succeeds")

func _phase_basic_data(delta):
	_data_test_timer += delta

	if _basic_server_got_data and _basic_client_got_data:
		_check(_basic_server_recv == BASIC_CLIENT_PAYLOAD,
			"Server received correct payload (got %s, expected %s)" % [
				_basic_server_recv.hex_encode(), BASIC_CLIENT_PAYLOAD.hex_encode()])
		_check(_basic_client_recv == BASIC_SERVER_PAYLOAD,
			"Client received correct payload (got %s, expected %s)" % [
				_basic_client_recv.hex_encode(), BASIC_SERVER_PAYLOAD.hex_encode()])
		_check(_basic_server_recv.size() == BASIC_CLIENT_PAYLOAD.size(),
			"Server received correct size (%d)" % _basic_server_recv.size())
		_check(_basic_client_recv.size() == BASIC_SERVER_PAYLOAD.size(),
			"Client received correct size (%d)" % _basic_client_recv.size())
		_log("  Basic data test complete.")
		_begin_multi_size()
		return

	if _data_test_timer > 10.0:
		_log("  TIMEOUT: server_got=%s client_got=%s" % [str(_basic_server_got_data), str(_basic_client_got_data)])
		_finish_test(false, "Basic data transfer timeout")

# ---------------------------------------------------------------
# Phase 4: Multi-size packet test
# ---------------------------------------------------------------

func _begin_multi_size():
	_log("")
	_log("--- Test: Multi-size packets (%s bytes) ---" % str(_multi_sizes))
	_phase = 4
	_data_test_timer = 0.0
	_multi_server_recv.clear()
	_multi_client_recv.clear()
	_multi_sent_to_server.clear()
	_multi_sent_to_client.clear()
	_multi_expect_count = _multi_sizes.size()

	var client_id = client_peer.get_unique_id()
	for i in _multi_sizes.size():
		var sz: int = _multi_sizes[i]
		var payload_cs = _make_payload(sz, 0xAA + i)
		_multi_sent_to_server.append(payload_cs)
		var err1 = client_mp.send_bytes(payload_cs, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		_log("  client -> server: %d bytes, sha256=%s, err=%s" % [
			sz, _sha256_hex(payload_cs).left(16), error_string(err1)])

		var payload_sc = _make_payload(sz, 0xBB + i)
		_multi_sent_to_client.append(payload_sc)
		var err2 = server_mp.send_bytes(payload_sc, client_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		_log("  server -> client: %d bytes, sha256=%s, err=%s" % [
			sz, _sha256_hex(payload_sc).left(16), error_string(err2)])

	_multi_send_done = true

func _phase_multi_size(delta):
	_data_test_timer += delta

	var srv_count = _multi_server_recv.size()
	var cli_count = _multi_client_recv.size()

	if srv_count >= _multi_expect_count and cli_count >= _multi_expect_count:
		_check(srv_count == _multi_expect_count,
			"Server received expected packet count (%d/%d)" % [srv_count, _multi_expect_count])
		_check(cli_count == _multi_expect_count,
			"Client received expected packet count (%d/%d)" % [cli_count, _multi_expect_count])

		var srv_ok := true
		var cli_ok := true
		for i in _multi_expect_count:
			if _multi_server_recv[i] != _multi_sent_to_server[i]:
				_log("  MISMATCH server packet %d: size got=%d expected=%d" % [
					i, _multi_server_recv[i].size(), _multi_sent_to_server[i].size()])
				srv_ok = false
			if _multi_client_recv[i] != _multi_sent_to_client[i]:
				_log("  MISMATCH client packet %d: size got=%d expected=%d" % [
					i, _multi_client_recv[i].size(), _multi_sent_to_client[i].size()])
				cli_ok = false

		_check(srv_ok, "All server-received packets match sent data")
		_check(cli_ok, "All client-received packets match sent data")
		_log("  Multi-size test complete.")
		_begin_burst()
		return

	if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
		_log("  ... multi-size: srv=%d/%d cli=%d/%d elapsed=%.1fs" % [
			srv_count, _multi_expect_count, cli_count, _multi_expect_count, _data_test_timer])

	if _data_test_timer > 15.0:
		_log("  TIMEOUT: srv=%d/%d cli=%d/%d" % [
			srv_count, _multi_expect_count, cli_count, _multi_expect_count])
		_finish_test(false, "Multi-size packet timeout")

# ---------------------------------------------------------------
# Phase 5: Burst test - rapid fire packets
# ---------------------------------------------------------------

func _begin_burst():
	_log("")
	_log("--- Test: Burst send (%d packets each direction) ---" % BURST_COUNT)
	_phase = 5
	_data_test_timer = 0.0
	_burst_server_recv.clear()
	_burst_client_recv.clear()
	_burst_sent_to_server.clear()
	_burst_sent_to_client.clear()

	var client_id = client_peer.get_unique_id()
	for i in BURST_COUNT:
		var payload_cs = PackedByteArray()
		payload_cs.resize(64)
		payload_cs[0] = (i >> 24) & 0xFF
		payload_cs[1] = (i >> 16) & 0xFF
		payload_cs[2] = (i >> 8) & 0xFF
		payload_cs[3] = i & 0xFF
		for j in range(4, 64):
			payload_cs[j] = (i + j) % 256
		_burst_sent_to_server.append(payload_cs)
		client_mp.send_bytes(payload_cs, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)

		var payload_sc = PackedByteArray()
		payload_sc.resize(64)
		payload_sc[0] = (i >> 24) & 0xFF
		payload_sc[1] = (i >> 16) & 0xFF
		payload_sc[2] = (i >> 8) & 0xFF
		payload_sc[3] = i & 0xFF
		for j in range(4, 64):
			payload_sc[j] = (i * 3 + j) % 256
		_burst_sent_to_client.append(payload_sc)
		server_mp.send_bytes(payload_sc, client_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)

	_burst_send_done = true
	_log("  Sent all %d packets in each direction" % BURST_COUNT)

func _phase_burst(delta):
	_data_test_timer += delta

	var srv_count = _burst_server_recv.size()
	var cli_count = _burst_client_recv.size()

	if srv_count >= BURST_COUNT and cli_count >= BURST_COUNT:
		_check(srv_count == BURST_COUNT,
			"Server received all burst packets (%d/%d)" % [srv_count, BURST_COUNT])
		_check(cli_count == BURST_COUNT,
			"Client received all burst packets (%d/%d)" % [cli_count, BURST_COUNT])

		var srv_order_ok := true
		var cli_order_ok := true
		var srv_content_ok := true
		var cli_content_ok := true

		for i in BURST_COUNT:
			var srv_seq = (_burst_server_recv[i][0] << 24) | (_burst_server_recv[i][1] << 16) | \
						  (_burst_server_recv[i][2] << 8) | _burst_server_recv[i][3]
			var cli_seq = (_burst_client_recv[i][0] << 24) | (_burst_client_recv[i][1] << 16) | \
						  (_burst_client_recv[i][2] << 8) | _burst_client_recv[i][3]
			if srv_seq != i:
				srv_order_ok = false
				_log("  Server burst order mismatch at %d: got seq %d" % [i, srv_seq])
			if cli_seq != i:
				cli_order_ok = false
				_log("  Client burst order mismatch at %d: got seq %d" % [i, cli_seq])
			if _burst_server_recv[i] != _burst_sent_to_server[i]:
				srv_content_ok = false
			if _burst_client_recv[i] != _burst_sent_to_client[i]:
				cli_content_ok = false

		_check(srv_order_ok, "Server burst packets in order")
		_check(cli_order_ok, "Client burst packets in order")
		_check(srv_content_ok, "Server burst packet contents match")
		_check(cli_content_ok, "Client burst packet contents match")
		_log("  Burst test complete.")
		_begin_hash_integrity()
		return

	if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
		_log("  ... burst: srv=%d/%d cli=%d/%d elapsed=%.1fs" % [
			srv_count, BURST_COUNT, cli_count, BURST_COUNT, _data_test_timer])

	if _data_test_timer > 15.0:
		_log("  TIMEOUT: srv=%d/%d cli=%d/%d" % [
			srv_count, BURST_COUNT, cli_count, BURST_COUNT])
		_finish_test(false, "Burst test timeout")

# ---------------------------------------------------------------
# Phase 6: Hash integrity - large payload with SHA-256 verification
# ---------------------------------------------------------------

func _begin_hash_integrity():
	_log("")
	_log("--- Test: SHA-256 hash integrity (%d byte payload) ---" % HASH_PAYLOAD_SIZE)
	_phase = 6
	_data_test_timer = 0.0

	_hash_sent_to_server = _make_payload(HASH_PAYLOAD_SIZE, 0x42)
	_hash_sent_to_client = _make_payload(HASH_PAYLOAD_SIZE, 0x7F)

	var hash_cs = _sha256_hex(_hash_sent_to_server)
	var hash_sc = _sha256_hex(_hash_sent_to_client)
	_log("  Payload to server: %d bytes, SHA-256=%s" % [HASH_PAYLOAD_SIZE, hash_cs])
	_log("  Payload to client: %d bytes, SHA-256=%s" % [HASH_PAYLOAD_SIZE, hash_sc])

	var client_id = client_peer.get_unique_id()
	var err1 = client_mp.send_bytes(_hash_sent_to_server, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	var err2 = server_mp.send_bytes(_hash_sent_to_client, client_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	_log("  client -> server: %s" % error_string(err1))
	_log("  server -> client: %s" % error_string(err2))
	_check(err1 == OK, "Large payload send (client->server) succeeds")
	_check(err2 == OK, "Large payload send (server->client) succeeds")

func _phase_hash_integrity(delta):
	_data_test_timer += delta

	if _hash_server_got and _hash_client_got:
		_check(_hash_server_recv.size() == HASH_PAYLOAD_SIZE,
			"Server received correct size (%d/%d)" % [_hash_server_recv.size(), HASH_PAYLOAD_SIZE])
		_check(_hash_client_recv.size() == HASH_PAYLOAD_SIZE,
			"Client received correct size (%d/%d)" % [_hash_client_recv.size(), HASH_PAYLOAD_SIZE])

		var srv_hash_sent = _sha256_hex(_hash_sent_to_server)
		var srv_hash_recv = _sha256_hex(_hash_server_recv)
		var cli_hash_sent = _sha256_hex(_hash_sent_to_client)
		var cli_hash_recv = _sha256_hex(_hash_client_recv)

		_log("  Server: sent_hash=%s recv_hash=%s" % [srv_hash_sent, srv_hash_recv])
		_log("  Client: sent_hash=%s recv_hash=%s" % [cli_hash_sent, cli_hash_recv])

		_check(srv_hash_sent == srv_hash_recv, "Server SHA-256 hash matches (no corruption)")
		_check(cli_hash_sent == cli_hash_recv, "Client SHA-256 hash matches (no corruption)")
		_check(_hash_server_recv == _hash_sent_to_server, "Server large payload byte-for-byte match")
		_check(_hash_client_recv == _hash_sent_to_client, "Client large payload byte-for-byte match")

		_log("  Hash integrity test complete.")
		_begin_ordering()
		return

	if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
		_log("  ... hash: server_got=%s client_got=%s elapsed=%.1fs" % [
			str(_hash_server_got), str(_hash_client_got), _data_test_timer])

	if _data_test_timer > 15.0:
		_log("  TIMEOUT: server_got=%s client_got=%s" % [
			str(_hash_server_got), str(_hash_client_got)])
		_finish_test(false, "Hash integrity timeout")

# ---------------------------------------------------------------
# Phase 7: Ordering - mixed sizes sent across multiple frames
# ---------------------------------------------------------------

func _begin_ordering():
	_log("")
	_log("--- Test: Packet ordering (%d packets, %d/frame, mixed sizes) ---" % [ORDER_TOTAL, ORDER_PER_FRAME])
	_phase = 7
	_data_test_timer = 0.0
	_order_server_recv.clear()
	_order_client_recv.clear()
	_order_sent_to_server.clear()
	_order_sent_to_client.clear()
	_order_send_idx = 0

	# Pre-generate all payloads so we can verify later
	for i in ORDER_TOTAL:
		# Alternate between small (32 byte) and large (512 byte) packets
		var sz := 32 if i % 2 == 0 else 512
		var pkt_cs = _encode_seq(i) + _make_payload(sz, 0xC0 + (i % 64))
		var pkt_sc = _encode_seq(i) + _make_payload(sz, 0xD0 + (i % 64))
		_order_sent_to_server.append(pkt_cs)
		_order_sent_to_client.append(pkt_sc)

func _phase_ordering(delta):
	_data_test_timer += delta

	# Send ORDER_PER_FRAME packets per frame until all sent
	if _order_send_idx < ORDER_TOTAL:
		var client_id = client_peer.get_unique_id()
		var end_idx = mini(_order_send_idx + ORDER_PER_FRAME, ORDER_TOTAL)
		for i in range(_order_send_idx, end_idx):
			client_mp.send_bytes(_order_sent_to_server[i], 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			server_mp.send_bytes(_order_sent_to_client[i], client_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		_order_send_idx = end_idx
		if _order_send_idx >= ORDER_TOTAL:
			_log("  All %d packets sent across %d frames" % [ORDER_TOTAL, ceili(float(ORDER_TOTAL) / ORDER_PER_FRAME)])
		return

	var srv_count = _order_server_recv.size()
	var cli_count = _order_client_recv.size()

	if srv_count >= ORDER_TOTAL and cli_count >= ORDER_TOTAL:
		_check(srv_count == ORDER_TOTAL,
			"Server received all ordering packets (%d/%d)" % [srv_count, ORDER_TOTAL])
		_check(cli_count == ORDER_TOTAL,
			"Client received all ordering packets (%d/%d)" % [cli_count, ORDER_TOTAL])

		# Check strict FIFO: sequence numbers must be 0,1,2,...,N-1
		var srv_fifo_ok := true
		var cli_fifo_ok := true
		var srv_content_ok := true
		var cli_content_ok := true

		for i in ORDER_TOTAL:
			var srv_seq = _decode_seq(_order_server_recv[i])
			var cli_seq = _decode_seq(_order_client_recv[i])
			if srv_seq != i:
				if srv_fifo_ok:  # Log first mismatch only
					_log("  Server FIFO break at index %d: expected seq %d, got %d" % [i, i, srv_seq])
				srv_fifo_ok = false
			if cli_seq != i:
				if cli_fifo_ok:
					_log("  Client FIFO break at index %d: expected seq %d, got %d" % [i, i, cli_seq])
				cli_fifo_ok = false
			if _order_server_recv[i] != _order_sent_to_server[i]:
				srv_content_ok = false
			if _order_client_recv[i] != _order_sent_to_client[i]:
				cli_content_ok = false

		_check(srv_fifo_ok, "Server packets in strict FIFO order")
		_check(cli_fifo_ok, "Client packets in strict FIFO order")
		_check(srv_content_ok, "Server ordering packet contents match (mixed 32/512 byte)")
		_check(cli_content_ok, "Client ordering packet contents match (mixed 32/512 byte)")

		# Verify no duplicates by checking all sequence numbers present
		var srv_seqs := {}
		var cli_seqs := {}
		for i in ORDER_TOTAL:
			srv_seqs[_decode_seq(_order_server_recv[i])] = true
			cli_seqs[_decode_seq(_order_client_recv[i])] = true
		_check(srv_seqs.size() == ORDER_TOTAL, "Server received no duplicate sequence numbers")
		_check(cli_seqs.size() == ORDER_TOTAL, "Client received no duplicate sequence numbers")

		_log("  Ordering test complete.")
		_begin_type_serialize()
		return

	if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
		_log("  ... ordering: srv=%d/%d cli=%d/%d elapsed=%.1fs" % [
			srv_count, ORDER_TOTAL, cli_count, ORDER_TOTAL, _data_test_timer])

	if _data_test_timer > 15.0:
		_log("  TIMEOUT: srv=%d/%d cli=%d/%d" % [
			srv_count, ORDER_TOTAL, cli_count, ORDER_TOTAL])
		_finish_test(false, "Ordering test timeout")

# ---------------------------------------------------------------
# Phase 8: Type serialization - Vector3, String, StringName, float, double
# ---------------------------------------------------------------

func _begin_type_serialize():
	_log("")
	_log("--- Test: Type serialization (var_to_bytes round-trip) ---")
	_phase = 8
	_data_test_timer = 0.0
	_type_server_recv.clear()
	_type_client_recv.clear()
	_type_sent_to_server.clear()
	_type_sent_to_client.clear()

	# Test values: each gets serialized, sent, received, deserialized, compared
	var test_values: Array = [
		Vector3(1.5, -2.75, 3.14159),
		Vector3(0.0, 0.0, 0.0),
		Vector3(999999.0, -999999.0, 0.001),
		"Hello Yggdrasil!",
		"",
		"Unicode: \u00e9\u00e0\u00fc\u00f1 \u2603 \u2764",
		&"StringNameTest",
		&"another_string_name",
		0.0,
		1.0,
		-1.0,
		3.14159265358979,      # float (64-bit in GDScript)
		1.7976931348623157e+308, # near max double
		2.2250738585072014e-308, # near min positive double
		INF,
		-INF,
		42,
		-1,
		0,
		2147483647,            # max 32-bit int
		true,
		false,
		Vector2(10.5, -20.25),
		Color(1.0, 0.5, 0.25, 0.8),
		Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)),
	]

	_type_expect_count = test_values.size()
	var client_id = client_peer.get_unique_id()

	for val in test_values:
		var bytes = var_to_bytes(val)
		_type_sent_to_server.append(val)
		_type_sent_to_client.append(val)

		var err1 = client_mp.send_bytes(bytes, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		var err2 = server_mp.send_bytes(bytes, client_id, MultiplayerPeer.TRANSFER_MODE_RELIABLE)

		var type_name = type_string(typeof(val))
		_log("  Sent %s (%s, %d bytes): c->s=%s s->c=%s" % [
			type_name, str(val).left(40), bytes.size(), error_string(err1), error_string(err2)])

func _phase_type_serialize(delta):
	_data_test_timer += delta

	var srv_count = _type_server_recv.size()
	var cli_count = _type_client_recv.size()

	if srv_count >= _type_expect_count and cli_count >= _type_expect_count:
		_check(srv_count == _type_expect_count,
			"Server received all type packets (%d/%d)" % [srv_count, _type_expect_count])
		_check(cli_count == _type_expect_count,
			"Client received all type packets (%d/%d)" % [cli_count, _type_expect_count])

		var all_srv_ok := true
		var all_cli_ok := true

		for i in _type_expect_count:
			var expected = _type_sent_to_server[i]
			var type_name = type_string(typeof(expected))

			var srv_val = bytes_to_var(_type_server_recv[i])
			var cli_val = bytes_to_var(_type_client_recv[i])

			# Type check
			var srv_type_ok = typeof(srv_val) == typeof(expected)
			var cli_type_ok = typeof(cli_val) == typeof(expected)

			# Value check (use is_equal_approx for floats/vectors)
			var srv_val_ok := false
			var cli_val_ok := false

			if expected is float:
				# Handle special float values
				if is_inf(expected) or is_nan(expected):
					srv_val_ok = str(srv_val) == str(expected)
					cli_val_ok = str(cli_val) == str(expected)
				else:
					srv_val_ok = is_equal_approx(srv_val, expected) if srv_type_ok else false
					cli_val_ok = is_equal_approx(cli_val, expected) if cli_type_ok else false
			elif expected is Vector3:
				srv_val_ok = srv_val.is_equal_approx(expected) if srv_type_ok else false
				cli_val_ok = cli_val.is_equal_approx(expected) if cli_type_ok else false
			elif expected is Vector2:
				srv_val_ok = srv_val.is_equal_approx(expected) if srv_type_ok else false
				cli_val_ok = cli_val.is_equal_approx(expected) if cli_type_ok else false
			elif expected is Transform3D:
				srv_val_ok = srv_val.is_equal_approx(expected) if srv_type_ok else false
				cli_val_ok = cli_val.is_equal_approx(expected) if cli_type_ok else false
			else:
				srv_val_ok = srv_val == expected
				cli_val_ok = cli_val == expected

			if not srv_type_ok or not srv_val_ok:
				_log("  Server type mismatch [%d] %s: sent=%s got=%s (type: %s vs %s)" % [
					i, type_name, str(expected).left(40), str(srv_val).left(40),
					type_string(typeof(expected)), type_string(typeof(srv_val))])
				all_srv_ok = false

			if not cli_type_ok or not cli_val_ok:
				_log("  Client type mismatch [%d] %s: sent=%s got=%s (type: %s vs %s)" % [
					i, type_name, str(expected).left(40), str(cli_val).left(40),
					type_string(typeof(expected)), type_string(typeof(cli_val))])
				all_cli_ok = false

		_check(all_srv_ok, "All server type round-trips match (Vector3/String/StringName/float/int/bool/etc)")
		_check(all_cli_ok, "All client type round-trips match (Vector3/String/StringName/float/int/bool/etc)")

		_log("  Type serialization test complete.")
		_begin_multi_peer()
		return

	if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
		_log("  ... type_serialize: srv=%d/%d cli=%d/%d elapsed=%.1fs" % [
			srv_count, _type_expect_count, cli_count, _type_expect_count, _data_test_timer])

	if _data_test_timer > 15.0:
		_log("  TIMEOUT: srv=%d/%d cli=%d/%d" % [
			srv_count, _type_expect_count, cli_count, _type_expect_count])
		_finish_test(false, "Type serialization timeout")

# ---------------------------------------------------------------
# Phase 9: Multi-peer - 5 clients connecting to same server
# ---------------------------------------------------------------

func _begin_multi_peer():
	_log("")
	_log("--- Test: Multi-peer (%d clients -> 1 server) ---" % MULTI_PEER_COUNT)
	_phase = 9
	_data_test_timer = 0.0
	_mp_server_recv.clear()
	_mp_all_connected = false
	_mp_broadcast_sent = false
	_mp_clients_sent = false
	_mp_clients.clear()

	# Close the original single client (keep server running)
	if client_mp:
		client_mp.peer_packet.disconnect(_on_client_packet)
	if client_peer:
		client_peer.close()
	client_peer = null
	client_mp = null

	var server_addr = server_peer.get_yggdrasil_address()

	for i in MULTI_PEER_COUNT:
		var peer = YggdrasilPeer.new()
		peer.set_debug_logging(true)
		var err = peer.create_client(server_addr, YGG_CONFIG)
		_log("  Client %d: create_client -> %s" % [i, error_string(err)])
		if err != OK:
			_log("  FATAL: Cannot create multi-peer client %d!" % i)
			_finish_test(false, "Multi-peer client creation failed")
			return

		var mp = SceneMultiplayer.new()
		mp.multiplayer_peer = peer

		var node = Node.new()
		node.name = "MPClient%d" % i
		add_child(node)
		get_tree().set_multiplayer(mp, NodePath("/root/YggConnectionTest/MPClient%d" % i))

		var client_info := {
			"peer": peer,
			"mp": mp,
			"node": node,
			"connected": false,
			"recv": [] as Array[PackedByteArray],
			"index": i,
			"known_peers": [] as Array[int],
		}

		# Capture client_info in closure
		var ci = client_info
		peer.peer_connected.connect(func(id):
			_log("  [SIGNAL] mp_client_%d.peer_connected(%d) known_before=%s" % [ci["index"], id, str(ci["known_peers"])])
			ci["known_peers"].append(id)
			ci["connected"] = true
		)
		peer.peer_disconnected.connect(func(id):
			_log("  [SIGNAL] mp_client_%d.peer_disconnected(%d)" % [ci["index"], id])
			ci["known_peers"].erase(id)
		)
		mp.peer_packet.connect(func(id, packet: PackedByteArray):
			if _log_packets:
				_log("  [RECV] mp_client_%d.peer_packet(from=%d, size=%d)" % [ci["index"], id, packet.size()])
			ci["recv"].append(packet)
		)

		_mp_clients.append(client_info)

	_log("  Created %d clients, waiting for connections..." % MULTI_PEER_COUNT)

func _phase_multi_peer(delta):
	_data_test_timer += delta

	# Step 1: Wait for all clients to connect
	if not _mp_all_connected:
		var connected_count := 0
		for c in _mp_clients:
			if c["connected"]:
				connected_count += 1

		if connected_count >= MULTI_PEER_COUNT:
			_mp_all_connected = true
			_log("  All %d clients connected (%.1fs)" % [MULTI_PEER_COUNT, _data_test_timer])

			# Verify each client got a unique peer ID
			var peer_ids := {}
			for c in _mp_clients:
				var pid = c["peer"].get_unique_id()
				_log("    Client %d: peer_id=%d" % [c["index"], pid])
				peer_ids[pid] = true
			_check(peer_ids.size() == MULTI_PEER_COUNT,
				"All %d clients have unique peer IDs" % MULTI_PEER_COUNT)
			return

		if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
			_log("  ... multi-peer connecting: %d/%d elapsed=%.1fs" % [
				connected_count, MULTI_PEER_COUNT, _data_test_timer])

		if _data_test_timer > 30.0:
			_log("  TIMEOUT waiting for multi-peer connections (%d/%d)" % [connected_count, MULTI_PEER_COUNT])
			_finish_test(false, "Multi-peer connection timeout")
		return

	# Step 2: Each client sends a unique packet to server
	if not _mp_clients_sent:
		_mp_clients_sent = true
		for c in _mp_clients:
			var tag = PackedByteArray([0xDD, c["index"]])
			var payload = tag + _make_payload(32, 0xE0 + c["index"])
			c["mp"].send_bytes(payload, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			_log("  Client %d -> server: %d bytes" % [c["index"], payload.size()])
		return

	# Step 3: Wait for server to receive all client packets
	if _mp_server_recv.size() < MULTI_PEER_COUNT:
		if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
			_log("  ... multi-peer server recv: %d/%d" % [_mp_server_recv.size(), MULTI_PEER_COUNT])
		if _data_test_timer > 30.0:
			_log("  TIMEOUT: server recv %d/%d" % [_mp_server_recv.size(), MULTI_PEER_COUNT])
			_finish_test(false, "Multi-peer server receive timeout")
		return

	# Step 4: Server broadcasts to all clients
	if not _mp_broadcast_sent:
		_mp_broadcast_sent = true
		_check(_mp_server_recv.size() == MULTI_PEER_COUNT,
			"Server received from all %d clients" % MULTI_PEER_COUNT)

		# Verify each client's tag byte is unique
		var tags := {}
		for pkt in _mp_server_recv:
			if pkt.size() >= 2:
				tags[pkt[1]] = true
		_check(tags.size() == MULTI_PEER_COUNT,
			"Server received unique tag from each client")

		# Broadcast a test packet from server to all
		var broadcast_payload = PackedByteArray([0xFF, 0xBB]) + _make_payload(64, 0xCC)
		server_mp.send_bytes(broadcast_payload, 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		_log("  Server broadcast -> all clients: %d bytes" % broadcast_payload.size())
		return

	# Step 5: Wait for all clients to receive the broadcast
	var all_got_broadcast := true
	for c in _mp_clients:
		if c["recv"].size() < 1:
			all_got_broadcast = false
			break

	if not all_got_broadcast:
		if int(_data_test_timer * 2) != int((_data_test_timer - delta) * 2):
			var recv_counts := []
			for c in _mp_clients:
				recv_counts.append(c["recv"].size())
			_log("  ... multi-peer broadcast recv: %s" % str(recv_counts))
		if _data_test_timer > 30.0:
			_finish_test(false, "Multi-peer broadcast timeout")
		return

	# Verify all clients received the broadcast
	var all_broadcast_ok := true
	var expected_broadcast = PackedByteArray([0xFF, 0xBB]) + _make_payload(64, 0xCC)
	for c in _mp_clients:
		if c["recv"][0] != expected_broadcast:
			_log("  Client %d broadcast mismatch: got %d bytes" % [c["index"], c["recv"][0].size()])
			all_broadcast_ok = false
	_check(all_broadcast_ok, "All %d clients received correct broadcast" % MULTI_PEER_COUNT)

	# Cleanup multi-peer clients
	for c in _mp_clients:
		c["peer"].close()
	_mp_clients.clear()

	_log("  Multi-peer test complete.")
	_begin_benchmark()

# ---------------------------------------------------------------
# Phase 10: Benchmark - throughput measurement
# ---------------------------------------------------------------

func _format_bytes(n: int) -> String:
	if n >= 1_000_000_000:
		return "%.1f GB" % (n / 1_000_000_000.0)
	elif n >= 1_000_000:
		return "%.1f MB" % (n / 1_000_000.0)
	elif n >= 1_000:
		return "%.1f KB" % (n / 1_000.0)
	else:
		return "%d B" % n

func _begin_benchmark():
	_log("")
	_log("========================================")
	_log("=== BENCHMARK: Throughput             ===")
	_log("========================================")
	_phase = 10
	_bench_idx = 0
	_bench_sub_phase = 0  # Start with connecting
	_bench_results.clear()
	_data_test_timer = 0.0

	# Create a fresh client for benchmarks
	_bench_known_peers.clear()
	var server_addr = server_peer.get_yggdrasil_address()
	_bench_client_peer = YggdrasilPeer.new()
	_bench_client_peer.set_debug_logging(true)
	var err = _bench_client_peer.create_client(server_addr, YGG_CONFIG)
	_log("  Benchmark client: create_client -> %s" % error_string(err))
	if err != OK:
		_finish_test(false, "Benchmark client creation failed")
		return

	_bench_client_mp = SceneMultiplayer.new()
	_bench_client_mp.multiplayer_peer = _bench_client_peer

	var node = Node.new()
	node.name = "BenchClient"
	add_child(node)
	get_tree().set_multiplayer(_bench_client_mp, ^"/root/YggConnectionTest/BenchClient")

	_bench_client_peer.peer_connected.connect(func(id):
		_log("  [SIGNAL] bench_client.peer_connected(%d) known_before=%s" % [id, str(_bench_known_peers)])
		_bench_known_peers.append(id)
		_bench_sub_phase = 1  # Ready to start benchmarking
	)
	_bench_client_peer.peer_disconnected.connect(func(id):
		_log("  [SIGNAL] bench_client.peer_disconnected(%d)" % id)
		_bench_known_peers.erase(id)
	)

	_log("  Waiting for benchmark client to connect...")
	_log("")
	_log("  %-12s  %10s  %8s  %12s" % ["Size", "Packets", "Time", "Throughput"])
	_log("  %s" % ("-".repeat(48)))

func _bench_start_size():
	var target_size: int = BENCH_SIZES[_bench_idx]
	_bench_target_bytes = target_size

	# Prepare chunk template
	var chunk_sz = mini(target_size, BENCH_CHUNK_SIZE)
	_bench_chunk_template = _make_payload(chunk_sz, 0xBE)

	# Calculate chunks needed
	if target_size <= chunk_sz:
		_bench_num_chunks = 1
		_bench_last_chunk = _bench_chunk_template.slice(0, target_size)
	else:
		_bench_num_chunks = ceili(float(target_size) / chunk_sz)
		var remainder = target_size % chunk_sz
		if remainder > 0:
			_bench_last_chunk = _bench_chunk_template.slice(0, remainder)
		else:
			_bench_last_chunk = _bench_chunk_template

	_bench_chunks_sent = 0
	_bench_bytes_recv = 0
	_bench_size_timer = 0.0
	_bench_start_usec = Time.get_ticks_usec()
	_bench_sub_phase = 2  # Sending

func _phase_benchmark(delta):
	_data_test_timer += delta

	# Sub-phase 0: Waiting for connection (handled by signal)
	if _bench_sub_phase == 0:
		if _data_test_timer > 30.0:
			_finish_test(false, "Benchmark client connection timeout")
		return

	# Sub-phase 1: Start next benchmark size
	if _bench_sub_phase == 1:
		if _bench_idx >= BENCH_SIZES.size():
			_bench_finish()
			return
		_bench_start_size()
		return

	# Sub-phase 2: Sending chunks
	if _bench_sub_phase == 2:
		_bench_size_timer += delta
		var sent_this_frame := 0
		while _bench_chunks_sent < _bench_num_chunks and sent_this_frame < BENCH_CHUNKS_PER_FRAME:
			var is_last = (_bench_chunks_sent == _bench_num_chunks - 1)
			var chunk = _bench_last_chunk if is_last else _bench_chunk_template
			_bench_client_mp.send_bytes(chunk, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
			_bench_chunks_sent += 1
			sent_this_frame += 1

		if _bench_chunks_sent >= _bench_num_chunks:
			_bench_sub_phase = 3  # Switch to waiting for receives
		return

	# Sub-phase 3: Waiting for all bytes to arrive
	if _bench_sub_phase == 3:
		_bench_size_timer += delta

		if _bench_bytes_recv >= _bench_target_bytes:
			var elapsed_usec = Time.get_ticks_usec() - _bench_start_usec
			var elapsed_ms = elapsed_usec / 1000.0
			var elapsed_sec = elapsed_usec / 1_000_000.0
			var mbps = (_bench_target_bytes / 1_000_000.0) / elapsed_sec if elapsed_sec > 0 else 0.0

			_log("  %-12s  %10d  %7.1fms  %10.2f MB/s" % [
				_format_bytes(_bench_target_bytes), _bench_num_chunks, elapsed_ms, mbps])

			_bench_results.append({
				"size": _bench_target_bytes,
				"packets": _bench_num_chunks,
				"time_ms": elapsed_ms,
				"mbps": mbps,
			})

			_bench_idx += 1
			_bench_sub_phase = 1  # Next size
			return

		if _bench_size_timer > BENCH_TIMEOUT_SEC:
			var elapsed_usec = Time.get_ticks_usec() - _bench_start_usec
			var elapsed_sec = elapsed_usec / 1_000_000.0
			var partial_mbps = (_bench_bytes_recv / 1_000_000.0) / elapsed_sec if elapsed_sec > 0 else 0.0

			_log("  %-12s  TIMEOUT after %.1fs (got %s/%s, ~%.2f MB/s)" % [
				_format_bytes(_bench_target_bytes), _bench_size_timer,
				_format_bytes(_bench_bytes_recv), _format_bytes(_bench_target_bytes), partial_mbps])

			_bench_results.append({
				"size": _bench_target_bytes,
				"packets": _bench_num_chunks,
				"time_ms": -1,
				"mbps": partial_mbps,
				"timeout": true,
			})

			_bench_idx += 1
			_bench_sub_phase = 1  # Next size
			return

func _bench_finish():
	_log("")
	_log("  Benchmark complete. Summary:")
	_log("  %-12s  %12s" % ["Size", "Throughput"])
	_log("  %s" % ("-".repeat(28)))
	for r in _bench_results:
		var status = "TIMEOUT (~%.2f MB/s)" % r["mbps"] if r.get("timeout", false) else "%.2f MB/s" % r["mbps"]
		_log("  %-12s  %s" % [_format_bytes(r["size"]), status])

	# Clean up benchmark client
	if _bench_client_peer:
		_bench_client_peer.close()
		_bench_client_peer = null
	_bench_client_mp = null

	_finish_test(true, "All test phases complete")

# ---------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------

func _finish_test(all_phases_done: bool, msg: String):
	_phase = 99
	_log("")
	_log("========================================")
	_log("=== TEST RESULTS                     ===")
	_log("========================================")
	_log("  Passed: %d" % _tests_passed)
	_log("  Failed: %d" % _tests_failed)
	_log("")

	var success = all_phases_done and _tests_failed == 0
	if success:
		_log("############## PASS: %s ##############" % msg)
	else:
		_log("############## FAIL: %s ##############" % msg)

	_log("")
	_log("Cleaning up...")

	# Close multi-peer clients if still around
	for c in _mp_clients:
		if c.has("peer") and c["peer"] != null:
			c["peer"].close()
	_mp_clients.clear()

	if _bench_client_peer:
		_bench_client_peer.close()
	if client_peer:
		client_peer.close()
	if server_peer:
		server_peer.close()
	_log("Done. Closing in 2 seconds...")

	if _log_file:
		_log_file.close()
		_log_file = null

	_shutdown_exit_code = 0 if success else 1
	_shutdown_timer = 2.0

func _exit_tree():
	for c in _mp_clients:
		if c.has("peer") and c["peer"] != null:
			c["peer"].close()
	if _bench_client_peer:
		_bench_client_peer.close()
	if client_peer:
		client_peer.close()
	if server_peer:
		server_peer.close()
	if _log_file:
		_log_file.close()
		_log_file = null
