#include "yggdrasil_peer.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

#include "libyggdrasil.h"

namespace godot {

// ---------------------------------------------------------------------------
// Big-endian helpers (used in protocol messages for peer ID encoding)
// ---------------------------------------------------------------------------

void YggdrasilPeer::write_u32_be(uint8_t *dst, uint32_t val) {
	dst[0] = (val >> 24) & 0xFF;
	dst[1] = (val >> 16) & 0xFF;
	dst[2] = (val >> 8) & 0xFF;
	dst[3] = val & 0xFF;
}

uint32_t YggdrasilPeer::read_u32_be(const uint8_t *src) {
	return ((uint32_t)src[0] << 24) | ((uint32_t)src[1] << 16) |
			((uint32_t)src[2] << 8) | src[3];
}

// ---------------------------------------------------------------------------
// Logging helpers - all messages tagged with [SERVER] or [CLIENT]
// ---------------------------------------------------------------------------

String YggdrasilPeer::_log_prefix() const {
	if (server_mode) {
		return "[SERVER] ";
	}
	int id = unique_id.load();
	if (id > 0) {
		return String("[CLIENT #") + String::num_int64(id) + "] ";
	}
	return "[CLIENT] ";
}

void YggdrasilPeer::_log(const String &msg) const {
	if (OS::get_singleton()->is_stdout_verbose()) {
		UtilityFunctions::print(_log_prefix() + msg);
	}
}

void YggdrasilPeer::_log_dbg(const String &msg) const {
	if (debug_logging && OS::get_singleton()->is_stdout_verbose()) {
		UtilityFunctions::print(_log_prefix() + msg);
	}
}

void YggdrasilPeer::_log_err(const String &msg) const {
	UtilityFunctions::printerr(_log_prefix() + msg);
}

// ---------------------------------------------------------------------------
// Log callback bridge - routes yggdrasil logs to Godot output
// ---------------------------------------------------------------------------

static void ygg_log_bridge(const char *msg, int level) {
	String godot_msg = String(msg);
	if (godot_msg.ends_with("\n")) {
		godot_msg = godot_msg.substr(0, godot_msg.length() - 1);
	}

	// Show [IW-SESSION] trace logs only when --verbose is passed to Godot
	if (godot_msg.begins_with("[IW-SESSION]")) {
		if (OS::get_singleton()->is_stdout_verbose()) {
			UtilityFunctions::print(godot_msg);
		}
		return;
	}

	// Only show warnings and errors from yggdrasil internals
	if (level < 3) {
		return;
	}
	godot_msg = String("[Yggdrasil] ") + godot_msg;
	if (level >= 4) {
		UtilityFunctions::printerr(godot_msg);
	} else {
		UtilityFunctions::print_rich("[color=yellow]" + godot_msg + "[/color]");
	}
}

// ---------------------------------------------------------------------------
// Construction / Destruction
// ---------------------------------------------------------------------------

YggdrasilPeer::YggdrasilPeer() {
}

YggdrasilPeer::~YggdrasilPeer() {
	_close();
}

// ---------------------------------------------------------------------------
// Bind methods for GDScript access
// ---------------------------------------------------------------------------

void YggdrasilPeer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("create_host", "config_json"), &YggdrasilPeer::create_host, DEFVAL("{}"));
	ClassDB::bind_method(D_METHOD("create_client", "server_identity", "config_json"), &YggdrasilPeer::create_client, DEFVAL("{}"));
	ClassDB::bind_method(D_METHOD("create_relay", "config_json"), &YggdrasilPeer::create_relay, DEFVAL("{}"));
	ClassDB::bind_method(D_METHOD("get_yggdrasil_address"), &YggdrasilPeer::get_yggdrasil_address);
	ClassDB::bind_method(D_METHOD("get_yggdrasil_public_key"), &YggdrasilPeer::get_yggdrasil_public_key);
	ClassDB::bind_method(D_METHOD("start_listener", "uri"), &YggdrasilPeer::start_listener);
	ClassDB::bind_method(D_METHOD("add_yggdrasil_peer", "uri"), &YggdrasilPeer::add_yggdrasil_peer);
	ClassDB::bind_method(D_METHOD("remove_yggdrasil_peer", "uri"), &YggdrasilPeer::remove_yggdrasil_peer);
	ClassDB::bind_method(D_METHOD("get_peers_info"), &YggdrasilPeer::get_peers_info);
	ClassDB::bind_method(D_METHOD("get_sessions_info"), &YggdrasilPeer::get_sessions_info);
	ClassDB::bind_method(D_METHOD("get_yggdrasil_version"), &YggdrasilPeer::get_yggdrasil_version);
	ClassDB::bind_method(D_METHOD("get_yggdrasil_mtu"), &YggdrasilPeer::get_yggdrasil_mtu);
	ClassDB::bind_method(D_METHOD("is_yggdrasil_server"), &YggdrasilPeer::is_yggdrasil_server);
	ClassDB::bind_method(D_METHOD("set_debug_logging", "enable"), &YggdrasilPeer::set_debug_logging);
	ClassDB::bind_method(D_METHOD("get_debug_logging"), &YggdrasilPeer::get_debug_logging);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_logging"), "set_debug_logging", "get_debug_logging");

	// Routing state
	ClassDB::bind_method(D_METHOD("has_route", "peer_key_hex"), &YggdrasilPeer::has_route);
	ClassDB::bind_method(D_METHOD("get_routing_entries"), &YggdrasilPeer::get_routing_entries);
	ClassDB::bind_method(D_METHOD("get_tree_entries"), &YggdrasilPeer::get_tree_entries);

	// Signals
	ADD_SIGNAL(MethodInfo("packet_dropped",
			PropertyInfo(Variant::STRING, "peer_key"),
			PropertyInfo(Variant::STRING, "error")));

	// Benchmark helpers
	ClassDB::bind_method(D_METHOD("benchmark_noop"), &YggdrasilPeer::benchmark_noop);
	ClassDB::bind_method(D_METHOD("benchmark_noop_data", "size"), &YggdrasilPeer::benchmark_noop_data);

	// Raw C API access (bypass MultiplayerPeer protocol)
	ClassDB::bind_method(D_METHOD("create_bare", "config_json"), &YggdrasilPeer::create_bare, DEFVAL("{}"));
	ClassDB::bind_method(D_METHOD("send_raw", "dest_key_hex", "data"), &YggdrasilPeer::send_raw);
	ClassDB::bind_method(D_METHOD("recv_raw", "timeout_ms"), &YggdrasilPeer::recv_raw);
	ClassDB::bind_method(D_METHOD("send_raw_unreliable", "dest_key_hex", "data"), &YggdrasilPeer::send_raw_unreliable);
	ClassDB::bind_method(D_METHOD("recv_raw_unreliable", "timeout_ms"), &YggdrasilPeer::recv_raw_unreliable);
}

// ---------------------------------------------------------------------------
// Node lifecycle
// ---------------------------------------------------------------------------

String YggdrasilPeer::_inject_listen_scheme(const String &config_json) {
	// Read transport protocol from project setting (default: "quic")
	String scheme = "quic";
	ProjectSettings *ps = ProjectSettings::get_singleton();
	if (ps && ps->has_setting("yggdrasil/transport/protocol")) {
		scheme = String(ps->get_setting("yggdrasil/transport/protocol"));
		if (scheme.is_empty()) {
			scheme = "quic";
		}
	}

	// Inject Listen via string manipulation to avoid Godot's JSON
	// round-trip converting ints to floats (Go rejects 0.0 for uint16).
	String cfg = config_json.strip_edges();
	String listen_val = "\"Listen\":[\"" + scheme + "://[::]:0\"]";
	if (cfg.begins_with("{") && cfg.length() > 2) {
		cfg = "{" + listen_val + "," + cfg.substr(1);
	} else {
		cfg = "{" + listen_val + "}";
	}

	_log_dbg(String("Transport protocol: ") + scheme);
	return cfg;
}

int YggdrasilPeer::_start_node(const String &config_json) {
	String final_config = _inject_listen_scheme(config_json);
	CharString utf8 = final_config.utf8();
	int handle = ygg_start(const_cast<char *>(utf8.get_data()), ygg_log_bridge);
	if (handle < 0) {
		const char *err = ygg_last_error();
		UtilityFunctions::printerr(String("[YGG] Failed to start node: ") +
				(err ? String(err) : String("unknown error")));
		return -1;
	}

	// Get IPv6 address (for display)
	char *addr = ygg_get_address(handle);
	if (addr) {
		own_addr_str = addr;
		ygg_free_string(addr);
	}

	// Get public key (for routing)
	char *pubkey = ygg_get_public_key(handle);
	if (pubkey) {
		own_pubkey_hex = pubkey;
		ygg_free_string(pubkey);
	}

	if (OS::get_singleton()->is_stdout_verbose()) {
		UtilityFunctions::print(String("[YGG] Node started, address: ") + String(own_addr_str.c_str()));
		UtilityFunctions::print(String("[YGG] Public key: ") + String(own_pubkey_hex.c_str()));

		char *ver = ygg_get_version();
		if (ver) {
			UtilityFunctions::print(String("[YGG] Yggdrasil version: ") + String(ver));
			ygg_free_string(ver);
		}
	}

	return handle;
}

void YggdrasilPeer::_stop_node() {
	running.store(false);

	if (ygg_handle >= 0) {
		ygg_stop(ygg_handle);
	}

	if (recv_thread.joinable()) {
		recv_thread.join();
	}
	if (dgram_recv_thread.joinable()) {
		dgram_recv_thread.join();
	}

	ygg_handle = -1;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

Error YggdrasilPeer::create_host(const String &config_json) {
	if (ygg_handle >= 0) {
		_log_err("Already active, call close() first");
		return ERR_ALREADY_IN_USE;
	}

	ygg_handle = _start_node(config_json);
	if (ygg_handle < 0) {
		return ERR_CANT_CREATE;
	}

	server_mode = true;
	unique_id.store(1);
	connection_status_val.store(CONNECTION_CONNECTED);

	// Start recv threads (reliable + unreliable datagram)
	running.store(true);
	recv_thread = std::thread(&YggdrasilPeer::_recv_loop, this);
	dgram_recv_thread = std::thread(&YggdrasilPeer::_dgram_recv_loop, this);

	_log_dbg("create_host() complete. peer_id=1, status=CONNECTED");
	_log(String("Listening on: ") + String(own_addr_str.c_str()));

	return OK;
}

Error YggdrasilPeer::create_client(const String &server_identity, const String &config_json) {
	if (ygg_handle >= 0) {
		_log_err("Already active, call close() first");
		return ERR_ALREADY_IN_USE;
	}

	ygg_handle = _start_node(config_json);
	if (ygg_handle < 0) {
		return ERR_CANT_CREATE;
	}

	// Accept either a public key hex (64 chars) or an IPv6 address
	CharString id_utf8 = server_identity.utf8();
	std::string id_str = id_utf8.get_data();

	if (id_str.find(':') != std::string::npos) {
		// Looks like an IPv6 address — resolve to public key via routing table
		_log_dbg(String("Resolving IPv6 address to public key: ") + server_identity);

		// Give the overlay a moment to discover peers before resolving.
		// The routing table needs to have seen the target node.
		// We'll retry resolution during _poll if it fails here.
		char *resolved = ygg_resolve_address(ygg_handle,
				const_cast<char *>(id_str.c_str()));
		if (resolved) {
			server_pubkey_hex = resolved;
			ygg_free_string(resolved);
			_log_dbg(String("Resolved to key: ") + String(server_pubkey_hex.c_str()));
		} else {
			// Store the address for deferred resolution in _poll
			_log_dbg("Address not yet in routing table, will retry resolution");
			server_addr_pending = id_str;
		}
	} else if (id_str.length() == 64) {
		server_pubkey_hex = id_str;
	} else {
		_log_err(String("Invalid server identity (expected 64-char hex key or IPv6 address): ") + server_identity);
		_stop_node();
		ygg_handle = -1;
		return ERR_INVALID_PARAMETER;
	}

	server_mode = false;
	unique_id.store(0); // Will be assigned by server
	connection_status_val.store(CONNECTION_CONNECTING);
	connect_pending.store(true);
	connect_retry_counter = 0;

	// Map server key to peer_id 1 (if resolved)
	if (!server_pubkey_hex.empty()) {
		key_to_peer[server_pubkey_hex] = 1;
		peer_to_key[1] = server_pubkey_hex;
	}

	// Start recv threads (reliable + unreliable datagram)
	running.store(true);
	recv_thread = std::thread(&YggdrasilPeer::_recv_loop, this);
	dgram_recv_thread = std::thread(&YggdrasilPeer::_dgram_recv_loop, this);

	_log_dbg(String("create_client() complete. status=CONNECTING, server=") + server_identity);

	// Send connect request if key is already resolved
	if (!server_pubkey_hex.empty()) {
		_send_protocol_msg(server_pubkey_hex, MSG_CONNECT_REQUEST);
	}

	return OK;
}

Error YggdrasilPeer::create_relay(const String &config_json) {
	if (ygg_handle >= 0) {
		_log_err("Already active, call close() first");
		return ERR_ALREADY_IN_USE;
	}

	ygg_handle = _start_node(config_json);
	if (ygg_handle < 0) {
		return ERR_CANT_CREATE;
	}

	// Relay nodes just participate in overlay routing — no recv thread,
	// no application I/O, no ipv6rwc activation.
	_log_dbg("create_relay() complete. Routing-only node.");
	return OK;
}

String YggdrasilPeer::get_yggdrasil_address() const {
	return String(own_addr_str.c_str());
}

String YggdrasilPeer::get_yggdrasil_public_key() const {
	return String(own_pubkey_hex.c_str());
}

Error YggdrasilPeer::add_yggdrasil_peer(const String &uri) {
	if (ygg_handle < 0) {
		return ERR_UNCONFIGURED;
	}
	CharString utf8 = uri.utf8();
	int ret = ygg_add_peer(ygg_handle, const_cast<char *>(utf8.get_data()), nullptr);
	if (ret < 0) {
		const char *err = ygg_last_error();
		_log_err(String("add_peer failed: ") +
				(err ? String(err) : String("unknown")));
		return ERR_CANT_CONNECT;
	}
	_log_dbg(String("Added yggdrasil peer: ") + uri);
	return OK;
}

String YggdrasilPeer::start_listener(const String &uri) {
	if (ygg_handle < 0) {
		_log_err("start_listener: node not started");
		return "";
	}
	CharString utf8 = uri.utf8();
	char *result = ygg_listen(ygg_handle, const_cast<char *>(utf8.get_data()));
	if (!result) {
		const char *err = ygg_last_error();
		_log_err(String("start_listener failed: ") +
				(err ? String(err) : String("unknown")));
		return "";
	}
	String actual_uri(result);
	ygg_free_string(result);
	_log(String("Listening on ") + actual_uri);
	return actual_uri;
}

Error YggdrasilPeer::remove_yggdrasil_peer(const String &uri) {
	if (ygg_handle < 0) {
		return ERR_UNCONFIGURED;
	}
	CharString utf8 = uri.utf8();
	int ret = ygg_remove_peer(ygg_handle, const_cast<char *>(utf8.get_data()), nullptr);
	if (ret < 0) {
		return ERR_CANT_CONNECT;
	}
	return OK;
}

String YggdrasilPeer::get_peers_info() const {
	if (ygg_handle < 0) {
		return "{}";
	}
	char *json = ygg_get_peers_json(ygg_handle);
	if (!json) {
		return "{}";
	}
	String result(json);
	ygg_free_string(json);
	return result;
}

String YggdrasilPeer::get_sessions_info() const {
	if (ygg_handle < 0) {
		return "{}";
	}
	char *json = ygg_get_sessions_json(ygg_handle);
	if (!json) {
		return "{}";
	}
	String result(json);
	ygg_free_string(json);
	return result;
}

String YggdrasilPeer::get_yggdrasil_version() const {
	char *ver = ygg_get_version();
	if (!ver) {
		return "";
	}
	String result(ver);
	ygg_free_string(ver);
	return result;
}

int YggdrasilPeer::get_yggdrasil_mtu() const {
	if (ygg_handle < 0) {
		return 0;
	}
	return ygg_get_mtu(ygg_handle);
}

// ---------------------------------------------------------------------------
// Recv thread - runs in background, queues incoming packets
// Uses core I/O (ygg_recv_from) — no ipv6rwc, no IPv6/UDP headers.
// ---------------------------------------------------------------------------

void YggdrasilPeer::_recv_loop() {
	const int BUF_SIZE = 65536;
	uint8_t *buffer = new uint8_t[BUF_SIZE];
	// Ed25519 public key = 32 bytes = 64 hex chars + null terminator
	const int KEY_BUF_SIZE = 65;
	char sender_key_buf[KEY_BUF_SIZE];

	_log_dbg("recv_thread: started (core I/O mode)");

	while (running.load()) {
		int n = ygg_recv_from(ygg_handle, buffer, BUF_SIZE,
				sender_key_buf, KEY_BUF_SIZE);
		if (n <= 0) {
			if (running.load()) {
				_log_err("recv_thread: ygg_recv_from returned <= 0, stopping");
			}
			break;
		}
		std::string sender_key(sender_key_buf);
		_process_packet(buffer, n, sender_key);
	}

	delete[] buffer;
	_log_dbg("recv_thread: stopped");
}

// ---------------------------------------------------------------------------
// Datagram recv thread - receives unreliable datagrams (QUIC RFC 9221)
// Uses 100ms timeout so the thread checks running flag periodically.
// ---------------------------------------------------------------------------

void YggdrasilPeer::_dgram_recv_loop() {
	const int BUF_SIZE = 65536;
	uint8_t *buffer = new uint8_t[BUF_SIZE];
	const int KEY_BUF_SIZE = 65;
	char sender_key_buf[KEY_BUF_SIZE];

	_log_dbg("dgram_recv_thread: started");

	while (running.load()) {
		int n = ygg_recv_from_unreliable(ygg_handle, buffer, BUF_SIZE,
				sender_key_buf, KEY_BUF_SIZE, 100);
		if (n == 0) {
			continue; // Timeout, check running flag
		}
		if (n < 0) {
			if (running.load()) {
				_log_err("dgram_recv_thread: ygg_recv_from_unreliable returned < 0, stopping");
			}
			break;
		}
		std::string sender_key(sender_key_buf);
		_process_packet(buffer, n, sender_key);
	}

	delete[] buffer;
	_log_dbg("dgram_recv_thread: stopped");
}

void YggdrasilPeer::_process_packet(const uint8_t *data, int len,
		const std::string &sender_key) {
	// Minimum: 1 byte msg_type
	if (len < 1) {
		return;
	}

	uint8_t msg_type = data[0];

	switch (msg_type) {
		case MSG_CONNECT_REQUEST:
			_log_dbg(String("recv: CONNECT_REQUEST from ") + String(sender_key.c_str()));
			_handle_connect_request(sender_key, data + 1, len - 1);
			break;
		case MSG_CONNECT_ACCEPT:
			_log_dbg("recv: CONNECT_ACCEPT from server");
			_handle_connect_accept(data + 1, len - 1);
			break;
		case MSG_CONNECT_REJECT:
			_log_err("recv: CONNECT_REJECT from server");
			connection_status_val.store(CONNECTION_DISCONNECTED);
			connect_pending.store(false);
			break;
		case MSG_DISCONNECT:
			_log_dbg(String("recv: DISCONNECT from ") + String(sender_key.c_str()));
			_handle_disconnect(sender_key, data + 1, len - 1);
			break;
		case MSG_DATA:
			_handle_data(sender_key, data + 1, len - 1);
			break;
		default:
			_log_dbg(String("recv: unknown msg_type=0x") + String::num_int64(msg_type, 16));
			break;
	}
}

void YggdrasilPeer::_handle_connect_request(const std::string &src_key,
		const uint8_t *payload, int len) {
	if (!server_mode) {
		return;
	}

	if (refuse_connections) {
		_send_protocol_msg(src_key, MSG_CONNECT_REJECT);
		return;
	}

	{
		std::lock_guard<std::mutex> lock(queue_mutex);

		// Check if already connected
		auto it = key_to_peer.find(src_key);
		if (it != key_to_peer.end()) {
			// Already known, resend accept
			int peer_id = it->second;
			uint8_t resp[4];
			write_u32_be(resp, peer_id);
			_send_protocol_msg(src_key, MSG_CONNECT_ACCEPT, resp, 4);
			return;
		}

		// Assign new peer ID
		int peer_id = next_peer_id++;
		key_to_peer[src_key] = peer_id;
		peer_to_key[peer_id] = src_key;

		// Send accept with assigned peer ID
		uint8_t resp[4];
		write_u32_be(resp, peer_id);
		_send_protocol_msg(src_key, MSG_CONNECT_ACCEPT, resp, 4);

		_log_dbg(String("Accepted peer #") + String::num_int64(peer_id) +
				String(" key=") + String(src_key.c_str()));

		// Queue peer_connected event for emission in _poll (main thread)
		{
			std::lock_guard<std::mutex> elock(event_mutex);
			pending_peer_connected.push_back(peer_id);
		}
	}
}

void YggdrasilPeer::_handle_connect_accept(const uint8_t *payload, int len) {
	if (server_mode || !connect_pending.load()) {
		return;
	}

	if (len < 4) {
		_log_err("CONNECT_ACCEPT payload too short");
		return;
	}

	int assigned_id = (int)read_u32_be(payload);
	connect_accepted_id = assigned_id;
	connect_pending.store(false);
	connect_accepted.store(true);

	_log_dbg(String("CONNECT_ACCEPT: assigned peer_id=") + String::num_int64(assigned_id));
}

void YggdrasilPeer::_handle_disconnect(const std::string &src_key,
		const uint8_t *payload, int len) {
	{
		std::lock_guard<std::mutex> lock(queue_mutex);

		auto it = key_to_peer.find(src_key);
		if (it == key_to_peer.end()) {
			return;
		}

		int peer_id = it->second;
		key_to_peer.erase(it);
		peer_to_key.erase(peer_id);

		_log_dbg(String("Peer #") + String::num_int64(peer_id) + String(" disconnected"));

		// Queue peer_disconnected event
		{
			std::lock_guard<std::mutex> elock(event_mutex);
			pending_peer_disconnected.push_back(peer_id);
		}

		if (!server_mode && peer_id == 1) {
			connection_status_val.store(CONNECTION_DISCONNECTED);
			_log_err("Lost connection to server");
		}
	}
}

void YggdrasilPeer::_handle_data(const std::string &src_key,
		const uint8_t *payload, int len) {
	// DATA payload: [4 bytes peer_id][1 byte transfer_mode][1 byte channel][data...]
	if (len < 6) {
		return;
	}

	int from_peer = (int)read_u32_be(payload);
	TransferMode mode = (TransferMode)payload[4];
	int channel = payload[5];
	const uint8_t *game_data = payload + 6;
	int game_data_len = len - 6;

	if (game_data_len <= 0) {
		return;
	}

	QueuedPacket pkt;
	pkt.data.resize(game_data_len);
	memcpy(pkt.data.ptrw(), game_data, game_data_len);
	pkt.from_peer = from_peer;
	pkt.mode = mode;
	pkt.channel = channel;

	std::lock_guard<std::mutex> lock(queue_mutex);
	incoming_queue.push_back(pkt);
}

// ---------------------------------------------------------------------------
// Routing state
// ---------------------------------------------------------------------------

bool YggdrasilPeer::has_route(const String &peer_key_hex) const {
	if (ygg_handle < 0) {
		return false;
	}
	CharString utf8 = peer_key_hex.utf8();
	return ygg_has_route(ygg_handle, const_cast<char *>(utf8.get_data())) != 0;
}

int YggdrasilPeer::get_routing_entries() const {
	if (ygg_handle < 0) {
		return 0;
	}
	return ygg_get_routing_entries(ygg_handle);
}

int YggdrasilPeer::get_tree_entries() const {
	if (ygg_handle < 0) {
		return 0;
	}
	return ygg_get_tree_entries(ygg_handle);
}

// ---------------------------------------------------------------------------
// Sending — uses core I/O (ygg_send_to with public key)
// ---------------------------------------------------------------------------

void YggdrasilPeer::_send_protocol_msg(const std::string &dest_key, MsgType type,
		const uint8_t *payload, int payload_len) {
	int total_len = 1 + payload_len;
	std::vector<uint8_t> msg(total_len);
	msg[0] = type;
	if (payload && payload_len > 0) {
		memcpy(&msg[1], payload, payload_len);
	}
	_send_to_key(dest_key, msg.data(), total_len);
}

void YggdrasilPeer::_send_to_key(const std::string &dest_key,
		const uint8_t *data, int data_len) {
	if (ygg_handle < 0) {
		return;
	}

	int ret = ygg_send_to(ygg_handle,
			const_cast<char *>(dest_key.c_str()),
			const_cast<uint8_t *>(data), data_len);
	if (ret < 0) {
		const char *err = ygg_last_error();
		std::string err_str = err ? err : "unknown";
		_log_err(String("_send_to_key failed: ") + String(err_str.c_str()));
		std::lock_guard<std::mutex> lock(drop_mutex);
		pending_drops.push_back({dest_key, err_str});
	}
}

void YggdrasilPeer::_send_to_key_unreliable(const std::string &dest_key,
		const uint8_t *data, int data_len) {
	if (ygg_handle < 0) {
		return;
	}

	int ret = ygg_send_to_unreliable(ygg_handle,
			const_cast<char *>(dest_key.c_str()),
			const_cast<uint8_t *>(data), data_len);
	if (ret < 0) {
		// Unreliable path unavailable — fall back to reliable.
		// _send_to_key handles its own drop reporting.
		_send_to_key(dest_key, data, data_len);
	}
}

// ---------------------------------------------------------------------------
// MultiplayerPeerExtension overrides
// ---------------------------------------------------------------------------

Error YggdrasilPeer::_get_packet(const uint8_t **r_buffer, int32_t *r_buffer_size) {
	std::lock_guard<std::mutex> lock(queue_mutex);
	if (incoming_queue.empty()) {
		return ERR_UNAVAILABLE;
	}

	// Pop front packet and keep it alive in current_packet
	current_packet = incoming_queue.front();
	incoming_queue.pop_front();
	has_current_packet = true;

	*r_buffer = current_packet.data.ptr();
	*r_buffer_size = current_packet.data.size();
	return OK;
}

Error YggdrasilPeer::_put_packet(const uint8_t *p_buffer, int32_t p_buffer_size) {
	if (ygg_handle < 0) {
		return ERR_UNCONFIGURED;
	}
	if (connection_status_val.load() != CONNECTION_CONNECTED) {
		return ERR_UNCONFIGURED;
	}

	// Build DATA payload: [4 bytes our_peer_id][1 byte mode][1 byte channel][game data]
	int payload_len = 4 + 1 + 1 + p_buffer_size;
	std::vector<uint8_t> payload(payload_len);
	write_u32_be(&payload[0], unique_id.load());
	payload[4] = (uint8_t)cur_transfer_mode;
	payload[5] = (uint8_t)cur_transfer_channel;
	memcpy(&payload[6], p_buffer, p_buffer_size);

	// Wrap in protocol message: [MSG_DATA][payload]
	int msg_len = 1 + payload_len;
	std::vector<uint8_t> msg(msg_len);
	msg[0] = MSG_DATA;
	memcpy(&msg[1], payload.data(), payload_len);

	// Use unreliable datagram path for UNRELIABLE / UNRELIABLE_ORDERED modes.
	// Falls back to reliable automatically if peer has no datagram support.
	bool use_unreliable = (cur_transfer_mode == TRANSFER_MODE_UNRELIABLE ||
			cur_transfer_mode == TRANSFER_MODE_UNRELIABLE_ORDERED);

	// Helper: send to a specific key and report drop if no route exists
	auto send_data_to = [&](const std::string &dest_key) {
		bool route_exists = ygg_has_route(ygg_handle,
				const_cast<char *>(dest_key.c_str())) != 0;
		if (use_unreliable) {
			_send_to_key_unreliable(dest_key, msg.data(), msg_len);
		} else {
			_send_to_key(dest_key, msg.data(), msg_len);
		}
		if (!route_exists) {
			std::lock_guard<std::mutex> dlock(drop_mutex);
			pending_drops.push_back({dest_key, "no route (packet silently dropped)"});
		}
	};

	if (!server_mode) {
		// Client always sends to server
		send_data_to(server_pubkey_hex);
	} else {
		// Server: route based on target_peer_id
		std::lock_guard<std::mutex> lock(queue_mutex);

		if (target_peer_id == 0) {
			// Broadcast to all connected clients
			for (const auto &pair : peer_to_key) {
				send_data_to(pair.second);
			}
		} else if (target_peer_id < 0) {
			// Send to all except |target_peer_id|
			int exclude = -target_peer_id;
			for (const auto &pair : peer_to_key) {
				if (pair.first != exclude) {
					send_data_to(pair.second);
				}
			}
		} else {
			// Send to specific peer
			auto it = peer_to_key.find(target_peer_id);
			if (it != peer_to_key.end()) {
				send_data_to(it->second);
			}
		}
	}

	return OK;
}

int32_t YggdrasilPeer::_get_available_packet_count() const {
	// Client buffers packets until CONNECTED so SceneMultiplayer doesn't
	// see data before peer_connected has been emitted.
	if (!server_mode && connection_status_val.load() != CONNECTION_CONNECTED) {
		return 0;
	}
	std::lock_guard<std::mutex> lock(queue_mutex);
	return (int32_t)incoming_queue.size();
}

int32_t YggdrasilPeer::_get_max_packet_size() const {
	int mtu = 65000;
	if (ygg_handle >= 0) {
		int ygg_mtu = ygg_get_mtu(ygg_handle);
		if (ygg_mtu > 0) {
			mtu = ygg_mtu - 7; // 1 msg_type + 4 peer_id + 1 mode + 1 channel
		}
	}
	return mtu > 0 ? mtu : 1200;
}

int32_t YggdrasilPeer::_get_packet_channel() const {
	std::lock_guard<std::mutex> lock(queue_mutex);
	if (!incoming_queue.empty()) {
		return incoming_queue.front().channel;
	}
	if (has_current_packet) {
		return current_packet.channel;
	}
	return 0;
}

MultiplayerPeer::TransferMode YggdrasilPeer::_get_packet_mode() const {
	std::lock_guard<std::mutex> lock(queue_mutex);
	if (!incoming_queue.empty()) {
		return incoming_queue.front().mode;
	}
	if (has_current_packet) {
		return current_packet.mode;
	}
	return TRANSFER_MODE_RELIABLE;
}

int32_t YggdrasilPeer::_get_packet_peer() const {
	std::lock_guard<std::mutex> lock(queue_mutex);
	if (!incoming_queue.empty()) {
		return incoming_queue.front().from_peer;
	}
	if (has_current_packet) {
		return current_packet.from_peer;
	}
	return 0;
}

void YggdrasilPeer::_set_transfer_channel(int32_t p_channel) {
	cur_transfer_channel = p_channel;
}

void YggdrasilPeer::_set_transfer_mode(MultiplayerPeer::TransferMode p_mode) {
	cur_transfer_mode = p_mode;
}

int32_t YggdrasilPeer::_get_transfer_channel() const {
	return cur_transfer_channel;
}

MultiplayerPeer::TransferMode YggdrasilPeer::_get_transfer_mode() const {
	return cur_transfer_mode;
}

MultiplayerPeer::ConnectionStatus YggdrasilPeer::_get_connection_status() const {
	return (ConnectionStatus)connection_status_val.load();
}

int32_t YggdrasilPeer::_get_unique_id() const {
	return unique_id.load();
}

void YggdrasilPeer::_poll() {
	// ---------------------------------------------------------------
	// STEP 1: Client - finalize connection if server accepted.
	//   Set CONNECTED *before* emitting peer_connected, because
	//   signal handlers (e.g. NetworkTime.start()) send packets
	//   via _put_packet which requires CONNECTION_CONNECTED.
	// ---------------------------------------------------------------
	if (connect_accepted.load() && !server_mode) {
		unique_id.store(connect_accepted_id);
		connect_accepted.store(false);
		connection_status_val.store(CONNECTION_CONNECTED);
		_log(String("Connected as peer #") + String::num_int64(connect_accepted_id));
		emit_signal("peer_connected", 1);
	}

	// ---------------------------------------------------------------
	// STEP 2: Emit peer connection/disconnection signals.
	//   Must happen on main thread. SceneMultiplayer listens to these
	//   to register peers in connected_peers before data arrives.
	// ---------------------------------------------------------------
	{
		std::lock_guard<std::mutex> lock(event_mutex);
		for (int id : pending_peer_connected) {
			_log_dbg(String("peer_connected(") + String::num_int64(id) + ")");
			emit_signal("peer_connected", id);
		}
		pending_peer_connected.clear();

		for (int id : pending_peer_disconnected) {
			_log_dbg(String("peer_disconnected(") + String::num_int64(id) + ")");
			emit_signal("peer_disconnected", id);
		}
		pending_peer_disconnected.clear();
	}

	// ---------------------------------------------------------------
	// STEP 2b: Emit packet_dropped signals (queued from send threads).
	// ---------------------------------------------------------------
	{
		std::lock_guard<std::mutex> lock(drop_mutex);
		for (const auto &drop : pending_drops) {
			emit_signal("packet_dropped",
					String(drop.peer_key.c_str()),
					String(drop.error.c_str()));
		}
		pending_drops.clear();
	}

	// ---------------------------------------------------------------
	// STEP 3: Client - resolve pending address and retry connect.
	//   Only send MSG_CONNECT_REQUEST when Ironwood has a route to
	//   the server — otherwise the packet is silently dropped.
	// ---------------------------------------------------------------
	if (connect_pending.load() && !server_mode) {
		// Deferred address resolution: if we were given an IPv6 address
		// that wasn't in the routing table at create_client time, retry.
		if (server_pubkey_hex.empty() && !server_addr_pending.empty()) {
			char *resolved = ygg_resolve_address(ygg_handle,
					const_cast<char *>(server_addr_pending.c_str()));
			if (resolved) {
				server_pubkey_hex = resolved;
				ygg_free_string(resolved);
				server_addr_pending.clear();
				key_to_peer[server_pubkey_hex] = 1;
				peer_to_key[1] = server_pubkey_hex;
				_log_dbg(String("Resolved server address to key: ") +
						String(server_pubkey_hex.c_str()));
			}
		}

		connect_retry_counter++;
		if (!server_pubkey_hex.empty() && connect_retry_counter % 5 == 0) {
			bool route_ready = ygg_has_route(ygg_handle,
					const_cast<char *>(server_pubkey_hex.c_str())) != 0;
			// Always send — ygg_send_to triggers SendLookup for path discovery.
			// Before route exists, the packet is silently dropped by Ironwood,
			// but the SendLookup side-effect drives route convergence.
			_send_protocol_msg(server_pubkey_hex, MSG_CONNECT_REQUEST);
			if (!route_ready && connect_retry_counter % 300 == 0) {
				_log_dbg(String("Waiting for route to server (routing_entries=") +
						String::num_int64(ygg_get_routing_entries(ygg_handle)) + ")");
			}
		}
	}
}

void YggdrasilPeer::_close() {
	if (ygg_handle < 0) {
		return;
	}

	_log_dbg("Closing connection...");

	// Notify connected peers
	if (server_mode) {
		std::lock_guard<std::mutex> lock(queue_mutex);
		for (const auto &pair : peer_to_key) {
			_send_protocol_msg(pair.second, MSG_DISCONNECT);
		}
	} else if (connection_status_val.load() == CONNECTION_CONNECTED) {
		_send_protocol_msg(server_pubkey_hex, MSG_DISCONNECT);
	}

	_stop_node();

	// Reset all state
	server_mode = false;
	unique_id.store(0);
	connection_status_val.store(CONNECTION_DISCONNECTED);
	connect_pending.store(false);
	connect_accepted.store(false);
	connect_accepted_id = 0;
	connect_retry_counter = 0;
	server_addr_pending.clear();
	key_to_peer.clear();
	peer_to_key.clear();
	next_peer_id = 2;
	incoming_queue.clear();
	has_current_packet = false;

	{
		std::lock_guard<std::mutex> lock(event_mutex);
		pending_peer_connected.clear();
		pending_peer_disconnected.clear();
	}
	{
		std::lock_guard<std::mutex> lock(drop_mutex);
		pending_drops.clear();
	}

	if (OS::get_singleton()->is_stdout_verbose()) {
		UtilityFunctions::print("[YGG] Connection closed, all state reset.");
	}
}

void YggdrasilPeer::_disconnect_peer(int32_t p_peer, bool p_force) {
	std::lock_guard<std::mutex> lock(queue_mutex);

	auto it = peer_to_key.find(p_peer);
	if (it == peer_to_key.end()) {
		return;
	}

	_send_protocol_msg(it->second, MSG_DISCONNECT);

	_log_dbg(String("Disconnected peer #") + String::num_int64(p_peer));

	key_to_peer.erase(it->second);
	peer_to_key.erase(it);

	{
		std::lock_guard<std::mutex> elock(event_mutex);
		pending_peer_disconnected.push_back(p_peer);
	}
}

void YggdrasilPeer::_set_target_peer(int32_t p_peer) {
	target_peer_id = p_peer;
}

bool YggdrasilPeer::_is_server() const {
	return server_mode;
}

bool YggdrasilPeer::is_yggdrasil_server() const {
	return server_mode;
}

void YggdrasilPeer::set_debug_logging(bool p_enable) {
	debug_logging = p_enable;
}

bool YggdrasilPeer::get_debug_logging() const {
	return debug_logging;
}

// ---------------------------------------------------------------------------
// Benchmark helpers
// ---------------------------------------------------------------------------

void YggdrasilPeer::benchmark_noop() {
	ygg_noop();
}

int YggdrasilPeer::benchmark_noop_data(int size) {
	if (size <= 0) {
		ygg_noop();
		return 0;
	}
	if (size <= 65536) {
		uint8_t buf[65536];
		buf[0] = 0xBE;
		ygg_noop_with_data(buf, size);
	} else {
		uint8_t *buf = new uint8_t[size];
		buf[0] = 0xBE;
		ygg_noop_with_data(buf, size);
		delete[] buf;
	}
	return size;
}

// ---------------------------------------------------------------------------
// Raw C API access — bypass MultiplayerPeer protocol entirely.
// For benchmarking: proves whether slowness is yggdrasil or SceneMultiplayer.
// ---------------------------------------------------------------------------

Error YggdrasilPeer::create_bare(const String &config_json) {
	if (ygg_handle >= 0) {
		_log_err("Already active, call close() first");
		return ERR_ALREADY_IN_USE;
	}

	ygg_handle = _start_node(config_json);
	if (ygg_handle < 0) {
		return ERR_CANT_CREATE;
	}

	// No recv threads, no server mode, no protocol.
	// Use send_raw()/recv_raw() for direct C API access.
	_log_dbg("create_bare() complete. Raw C API mode — no recv threads.");
	return OK;
}

int YggdrasilPeer::send_raw(const String &dest_key_hex, const PackedByteArray &data) {
	if (ygg_handle < 0) {
		return -1;
	}
	CharString key_utf8 = dest_key_hex.utf8();
	return ygg_send_to(ygg_handle,
			const_cast<char *>(key_utf8.get_data()),
			const_cast<uint8_t *>(data.ptr()), data.size());
}

Dictionary YggdrasilPeer::recv_raw(int timeout_ms) {
	Dictionary result;
	if (ygg_handle < 0) {
		return result;
	}

	uint8_t buf[65536];
	char sender_key[65];

	int n = ygg_recv_from_timeout(ygg_handle, buf, sizeof(buf),
			sender_key, sizeof(sender_key), timeout_ms);
	if (n <= 0) {
		return result; // Empty dict = timeout or error
	}

	PackedByteArray pkt;
	pkt.resize(n);
	memcpy(pkt.ptrw(), buf, n);

	result["data"] = pkt;
	result["sender"] = String(sender_key);
	return result;
}

int YggdrasilPeer::send_raw_unreliable(const String &dest_key_hex, const PackedByteArray &data) {
	if (ygg_handle < 0) {
		return -1;
	}
	CharString key_utf8 = dest_key_hex.utf8();
	return ygg_send_to_unreliable(ygg_handle,
			const_cast<char *>(key_utf8.get_data()),
			const_cast<uint8_t *>(data.ptr()), data.size());
}

Dictionary YggdrasilPeer::recv_raw_unreliable(int timeout_ms) {
	Dictionary result;
	if (ygg_handle < 0) {
		return result;
	}

	uint8_t buf[65536];
	char sender_key[65];

	int n = ygg_recv_from_unreliable(ygg_handle, buf, sizeof(buf),
			sender_key, sizeof(sender_key), timeout_ms);
	if (n <= 0) {
		return result; // Empty dict = timeout or error
	}

	PackedByteArray pkt;
	pkt.resize(n);
	memcpy(pkt.ptrw(), buf, n);

	result["data"] = pkt;
	result["sender"] = String(sender_key);
	return result;
}

bool YggdrasilPeer::_is_server_relay_supported() const {
	return true;
}

bool YggdrasilPeer::_is_refusing_new_connections() const {
	return refuse_connections;
}

void YggdrasilPeer::_set_refuse_new_connections(bool p_enable) {
	refuse_connections = p_enable;
}

} // namespace godot
