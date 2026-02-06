#include "yggdrasil_peer.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif
#include <cstring>

#include "libyggdrasil.h"

namespace godot {

// ---------------------------------------------------------------------------
// IPv6 + UDP packet helpers
// ---------------------------------------------------------------------------

static void write_u16_be(uint8_t *dst, uint16_t val) {
	dst[0] = (val >> 8) & 0xFF;
	dst[1] = val & 0xFF;
}

static uint16_t read_u16_be(const uint8_t *src) {
	return ((uint16_t)src[0] << 8) | src[1];
}

static void write_u32_be(uint8_t *dst, uint32_t val) {
	dst[0] = (val >> 24) & 0xFF;
	dst[1] = (val >> 16) & 0xFF;
	dst[2] = (val >> 8) & 0xFF;
	dst[3] = val & 0xFF;
}

static uint32_t read_u32_be(const uint8_t *src) {
	return ((uint32_t)src[0] << 24) | ((uint32_t)src[1] << 16) |
			((uint32_t)src[2] << 8) | src[3];
}

bool YggdrasilPeer::parse_ipv6_addr(const std::string &str, uint8_t out[16]) {
	struct in6_addr addr;
	if (inet_pton(AF_INET6, str.c_str(), &addr) == 1) {
		memcpy(out, &addr, 16);
		return true;
	}
	return false;
}

std::string YggdrasilPeer::format_ipv6_addr(const uint8_t addr[16]) {
	char buf[INET6_ADDRSTRLEN];
	inet_ntop(AF_INET6, addr, buf, sizeof(buf));
	return std::string(buf);
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
	UtilityFunctions::print(_log_prefix() + msg);
}

void YggdrasilPeer::_log_dbg(const String &msg) const {
	if (debug_logging) {
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
	// Only show warnings and errors from yggdrasil internals
	if (level < 3) {
		return;
	}
	String godot_msg = String("[Yggdrasil] ") + String(msg);
	if (godot_msg.ends_with("\n")) {
		godot_msg = godot_msg.substr(0, godot_msg.length() - 1);
	}
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
	ClassDB::bind_method(D_METHOD("create_client", "server_address", "config_json"), &YggdrasilPeer::create_client, DEFVAL("{}"));
	ClassDB::bind_method(D_METHOD("get_yggdrasil_address"), &YggdrasilPeer::get_yggdrasil_address);
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

	// Benchmark helpers
	ClassDB::bind_method(D_METHOD("benchmark_noop"), &YggdrasilPeer::benchmark_noop);
	ClassDB::bind_method(D_METHOD("benchmark_noop_data", "size"), &YggdrasilPeer::benchmark_noop_data);
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
	// Always prepend — if user also provides a top-level Listen array later
	// in the JSON, Go's unmarshaler uses the last value so theirs wins.
	// Note: can't check for "Listen" key — MulticastInterfaces has a
	// "Listen": true boolean that gives a false positive.
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

	char *addr = ygg_get_address(handle);
	if (addr) {
		own_addr_str = addr;
		parse_ipv6_addr(own_addr_str, own_addr_bytes);
		ygg_free_string(addr);
	}

	UtilityFunctions::print(String("[YGG] Node started, address: ") + String(own_addr_str.c_str()));

	char *ver = ygg_get_version();
	if (ver) {
		UtilityFunctions::print(String("[YGG] Yggdrasil version: ") + String(ver));
		ygg_free_string(ver);
	}

	char *pubkey = ygg_get_public_key(handle);
	if (pubkey) {
		UtilityFunctions::print(String("[YGG] Public key: ") + String(pubkey));
		ygg_free_string(pubkey);
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

	// Start recv thread
	running.store(true);
	recv_thread = std::thread(&YggdrasilPeer::_recv_loop, this);

	_log_dbg("create_host() complete. peer_id=1, status=CONNECTED");
	_log(String("Listening on: ") + String(own_addr_str.c_str()));

	return OK;
}

Error YggdrasilPeer::create_client(const String &server_address, const String &config_json) {
	if (ygg_handle >= 0) {
		_log_err("Already active, call close() first");
		return ERR_ALREADY_IN_USE;
	}

	CharString addr_utf8 = server_address.utf8();
	server_addr_str = addr_utf8.get_data();
	if (!parse_ipv6_addr(server_addr_str, server_addr_bytes)) {
		_log_err(String("Invalid server address: ") + server_address);
		return ERR_INVALID_PARAMETER;
	}

	ygg_handle = _start_node(config_json);
	if (ygg_handle < 0) {
		return ERR_CANT_CREATE;
	}

	server_mode = false;
	unique_id.store(0); // Will be assigned by server
	connection_status_val.store(CONNECTION_CONNECTING);
	connect_pending.store(true);
	connect_retry_counter = 0;

	// Map server address to peer_id 1
	addr_to_peer[server_addr_str] = 1;
	peer_to_addr[1] = server_addr_str;

	// Start recv thread
	running.store(true);
	recv_thread = std::thread(&YggdrasilPeer::_recv_loop, this);

	_log_dbg(String("create_client() complete. status=CONNECTING, server=") + server_address);
	_send_protocol_msg(server_addr_bytes, MSG_CONNECT_REQUEST);

	return OK;
}

String YggdrasilPeer::get_yggdrasil_address() const {
	return String(own_addr_str.c_str());
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
// ---------------------------------------------------------------------------

void YggdrasilPeer::_recv_loop() {
	const int BUF_SIZE = 65536;
	uint8_t *buffer = new uint8_t[BUF_SIZE];

	_log_dbg("recv_thread: started");

	while (running.load()) {
		int n = ygg_recv(ygg_handle, buffer, BUF_SIZE);
		if (n <= 0) {
			if (running.load()) {
				_log_err("recv_thread: ygg_recv returned <= 0, stopping");
			}
			break;
		}
		_process_raw_packet(buffer, n);
	}

	delete[] buffer;
	_log_dbg("recv_thread: stopped");
}

void YggdrasilPeer::_process_raw_packet(const uint8_t *data, int len) {
	// Minimum: 40 (IPv6) + 8 (UDP) + 1 (msg_type) = 49
	if (len < 49) {
		return;
	}

	// Verify IPv6 version
	if ((data[0] >> 4) != 6) {
		return;
	}

	// Extract source address (bytes 8-23)
	const uint8_t *src_addr = data + 8;

	// Check next header = 17 (UDP)
	if (data[6] != 17) {
		return;
	}

	// UDP header at byte 40
	uint16_t dst_port = read_u16_be(data + 42);
	if (dst_port != GAME_PORT) {
		return;
	}

	// UDP payload starts at byte 48
	const uint8_t *payload = data + 48;
	int payload_len = len - 48;

	if (payload_len < 1) {
		return;
	}

	uint8_t msg_type = payload[0];

	switch (msg_type) {
		case MSG_CONNECT_REQUEST:
			_log_dbg(String("recv: CONNECT_REQUEST from ") + String(format_ipv6_addr(src_addr).c_str()));
			_handle_connect_request(src_addr, payload + 1, payload_len - 1);
			break;
		case MSG_CONNECT_ACCEPT:
			_log_dbg("recv: CONNECT_ACCEPT from server");
			_handle_connect_accept(payload + 1, payload_len - 1);
			break;
		case MSG_CONNECT_REJECT:
			_log_err("recv: CONNECT_REJECT from server");
			connection_status_val.store(CONNECTION_DISCONNECTED);
			connect_pending.store(false);
			break;
		case MSG_DISCONNECT:
			_log_dbg(String("recv: DISCONNECT from ") + String(format_ipv6_addr(src_addr).c_str()));
			_handle_disconnect(src_addr, payload + 1, payload_len - 1);
			break;
		case MSG_DATA:
			_handle_data(src_addr, payload + 1, payload_len - 1);
			break;
		default:
			_log_dbg(String("recv: unknown msg_type=0x") + String::num_int64(msg_type, 16));
			break;
	}
}

void YggdrasilPeer::_handle_connect_request(const uint8_t src_addr[16], const uint8_t *payload, int len) {
	if (!server_mode) {
		return;
	}

	if (refuse_connections) {
		_send_protocol_msg(src_addr, MSG_CONNECT_REJECT);
		return;
	}

	std::string addr_str = format_ipv6_addr(src_addr);

	{
		std::lock_guard<std::mutex> lock(queue_mutex);

		// Check if already connected
		auto it = addr_to_peer.find(addr_str);
		if (it != addr_to_peer.end()) {
			// Already known, resend accept
			int peer_id = it->second;
			uint8_t resp[4];
			write_u32_be(resp, peer_id);
			_send_protocol_msg(src_addr, MSG_CONNECT_ACCEPT, resp, 4);
			return;
		}

		// Assign new peer ID
		int peer_id = next_peer_id++;
		addr_to_peer[addr_str] = peer_id;
		peer_to_addr[peer_id] = addr_str;

		// Send accept with assigned peer ID
		uint8_t resp[4];
		write_u32_be(resp, peer_id);
		_send_protocol_msg(src_addr, MSG_CONNECT_ACCEPT, resp, 4);

		_log_dbg(String("Accepted peer #") + String::num_int64(peer_id) +
				String(" from ") + String(addr_str.c_str()));

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

void YggdrasilPeer::_handle_disconnect(const uint8_t src_addr[16], const uint8_t *payload, int len) {
	std::string addr_str = format_ipv6_addr(src_addr);

	{
		std::lock_guard<std::mutex> lock(queue_mutex);

		auto it = addr_to_peer.find(addr_str);
		if (it == addr_to_peer.end()) {
			return;
		}

		int peer_id = it->second;
		addr_to_peer.erase(it);
		peer_to_addr.erase(peer_id);

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

void YggdrasilPeer::_handle_data(const uint8_t src_addr[16], const uint8_t *payload, int len) {
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
// Sending
// ---------------------------------------------------------------------------

void YggdrasilPeer::_send_protocol_msg(const uint8_t dest_addr[16], MsgType type,
		const uint8_t *payload, int payload_len) {
	int udp_payload_len = 1 + payload_len;
	std::vector<uint8_t> udp_payload(udp_payload_len);
	udp_payload[0] = type;
	if (payload && payload_len > 0) {
		memcpy(&udp_payload[1], payload, payload_len);
	}
	_send_ipv6_packet(dest_addr, udp_payload.data(), udp_payload_len);
}

void YggdrasilPeer::_send_ipv6_packet(const uint8_t dest_addr[16],
		const uint8_t *udp_payload, int udp_payload_len) {
	if (ygg_handle < 0) {
		return;
	}

	// Total: 40 (IPv6 header) + 8 (UDP header) + udp_payload_len
	int total_len = 40 + 8 + udp_payload_len;
	std::vector<uint8_t> packet(total_len, 0);

	// IPv6 header
	packet[0] = 0x60; // Version 6
	uint16_t ipv6_payload_len = 8 + udp_payload_len;
	write_u16_be(&packet[4], ipv6_payload_len);
	packet[6] = 17; // Next header: UDP
	packet[7] = 64; // Hop limit
	memcpy(&packet[8], own_addr_bytes, 16);  // Source address
	memcpy(&packet[24], dest_addr, 16);      // Destination address

	// UDP header
	write_u16_be(&packet[40], GAME_PORT); // Source port
	write_u16_be(&packet[42], GAME_PORT); // Dest port
	write_u16_be(&packet[44], 8 + udp_payload_len); // UDP length
	write_u16_be(&packet[46], 0); // Checksum (not validated by yggdrasil internal routing)

	// UDP payload
	memcpy(&packet[48], udp_payload, udp_payload_len);

	int ret = ygg_send(ygg_handle, packet.data(), total_len);
	if (ret < 0) {
		const char *err = ygg_last_error();
		_log_err(String("_send_ipv6_packet failed: ") +
				(err ? String(err) : String("unknown")));
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

	// Wrap in protocol message
	int udp_payload_len = 1 + payload_len;
	std::vector<uint8_t> udp_payload(udp_payload_len);
	udp_payload[0] = MSG_DATA;
	memcpy(&udp_payload[1], payload.data(), payload_len);

	auto send_to_addr = [&](const std::string &addr_str) {
		uint8_t addr_bytes[16];
		if (parse_ipv6_addr(addr_str, addr_bytes)) {
			_send_ipv6_packet(addr_bytes, udp_payload.data(), udp_payload_len);
		}
	};

	if (!server_mode) {
		// Client always sends to server
		send_to_addr(server_addr_str);
	} else {
		// Server: route based on target_peer_id
		std::lock_guard<std::mutex> lock(queue_mutex);

		if (target_peer_id == 0) {
			// Broadcast to all connected clients
			for (const auto &pair : peer_to_addr) {
				send_to_addr(pair.second);
			}
		} else if (target_peer_id < 0) {
			// Send to all except |target_peer_id|
			int exclude = -target_peer_id;
			for (const auto &pair : peer_to_addr) {
				if (pair.first != exclude) {
					send_to_addr(pair.second);
				}
			}
		} else {
			// Send to specific peer
			auto it = peer_to_addr.find(target_peer_id);
			if (it != peer_to_addr.end()) {
				send_to_addr(it->second);
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
			mtu = ygg_mtu - 55; // 40 IPv6 + 8 UDP + 7 protocol header
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
	// STEP 3: (removed) Packets are now read directly from incoming_queue
	//   by _get_packet(). Client buffering is handled by
	//   _get_available_packet_count() returning 0 until CONNECTED.
	// ---------------------------------------------------------------

	// ---------------------------------------------------------------
	// STEP 4: Client - retry connect request if still pending.
	// ---------------------------------------------------------------
	if (connect_pending.load() && !server_mode) {
		connect_retry_counter++;
		if (connect_retry_counter % 5 == 0) {
			_send_protocol_msg(server_addr_bytes, MSG_CONNECT_REQUEST);
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
		for (const auto &pair : peer_to_addr) {
			uint8_t addr_bytes[16];
			if (parse_ipv6_addr(pair.second, addr_bytes)) {
				_send_protocol_msg(addr_bytes, MSG_DISCONNECT);
			}
		}
	} else if (connection_status_val.load() == CONNECTION_CONNECTED) {
		_send_protocol_msg(server_addr_bytes, MSG_DISCONNECT);
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
	addr_to_peer.clear();
	peer_to_addr.clear();
	next_peer_id = 2;
	incoming_queue.clear();
	has_current_packet = false;

	{
		std::lock_guard<std::mutex> lock(event_mutex);
		pending_peer_connected.clear();
		pending_peer_disconnected.clear();
	}

	UtilityFunctions::print("[YGG] Connection closed, all state reset.");
}

void YggdrasilPeer::_disconnect_peer(int32_t p_peer, bool p_force) {
	std::lock_guard<std::mutex> lock(queue_mutex);

	auto it = peer_to_addr.find(p_peer);
	if (it == peer_to_addr.end()) {
		return;
	}

	uint8_t addr_bytes[16];
	if (parse_ipv6_addr(it->second, addr_bytes)) {
		_send_protocol_msg(addr_bytes, MSG_DISCONNECT);
	}

	_log_dbg(String("Disconnected peer #") + String::num_int64(p_peer));

	addr_to_peer.erase(it->second);
	peer_to_addr.erase(it);

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
