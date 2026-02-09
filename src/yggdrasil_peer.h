#ifndef YGGDRASIL_PEER_H
#define YGGDRASIL_PEER_H

#include <godot_cpp/classes/multiplayer_peer_extension.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace godot {

class YggdrasilPeer : public MultiplayerPeerExtension {
	GDCLASS(YggdrasilPeer, MultiplayerPeerExtension);

public:
	// Protocol message types
	enum MsgType : uint8_t {
		MSG_CONNECT_REQUEST = 0x01,
		MSG_CONNECT_ACCEPT = 0x02,
		MSG_CONNECT_REJECT = 0x03,
		MSG_DISCONNECT = 0x04,
		MSG_DATA = 0x05,
		MSG_PING = 0x06,
		MSG_PONG = 0x07,
	};

private:
	struct QueuedPacket {
		PackedByteArray data;
		int from_peer;
		TransferMode mode;
		int channel;
	};

	// Yggdrasil node handle
	int ygg_handle = -1;
	bool server_mode = false; // Set before recv thread starts, read-only after
	std::atomic<int> unique_id{0};
	std::atomic<int> connection_status_val{CONNECTION_DISCONNECTED};
	bool refuse_connections = false;
	bool debug_logging = false;

	// Transfer settings
	TransferMode cur_transfer_mode = TRANSFER_MODE_RELIABLE;
	int cur_transfer_channel = 0;
	int target_peer_id = 0;

	// Single packet queue: recv thread pushes, main thread pops directly
	std::deque<QueuedPacket> incoming_queue;
	mutable std::mutex queue_mutex;

	// Current packet being read (kept alive for pointer validity)
	QueuedPacket current_packet;
	bool has_current_packet = false;

	// Peer tracking: maps yggdrasil public key hex <-> Godot peer ID
	std::map<std::string, int> key_to_peer;
	std::map<int, std::string> peer_to_key;
	int next_peer_id = 2; // 1 is reserved for server

	// Peer connection/disconnection events (thread-safe, emitted in _poll)
	std::vector<int> pending_peer_connected;
	std::vector<int> pending_peer_disconnected;
	std::mutex event_mutex;

	// Packet drop events (written by any thread, emitted in _poll on main thread)
	struct DropEvent {
		std::string peer_key;
		std::string error;
	};
	std::vector<DropEvent> pending_drops;
	std::mutex drop_mutex;

	// Own yggdrasil identity
	std::string own_addr_str;      // IPv6 address (for display)
	std::string own_pubkey_hex;    // Public key hex (64 chars, for routing)

	// Server identity (for clients)
	std::string server_pubkey_hex;
	std::string server_addr_pending; // IPv6 address awaiting resolution to pubkey

	// Recv threads (reliable + unreliable datagram)
	std::thread recv_thread;
	std::thread dgram_recv_thread;
	std::atomic<bool> running{false};

	// Pending connection (client waiting for accept)
	std::atomic<bool> connect_pending{false};
	std::atomic<bool> connect_accepted{false}; // Set by recv thread, consumed by _poll
	int connect_accepted_id = 0; // Assigned peer ID, written by recv thread before connect_accepted
	int connect_retry_counter = 0;

	// Internal helpers
	void _recv_loop();
	void _dgram_recv_loop();
	void _process_packet(const uint8_t *data, int len, const std::string &sender_key);
	void _handle_connect_request(const std::string &src_key, const uint8_t *payload, int len);
	void _handle_connect_accept(const uint8_t *payload, int len);
	void _handle_disconnect(const std::string &src_key, const uint8_t *payload, int len);
	void _handle_data(const std::string &src_key, const uint8_t *payload, int len);

	void _send_protocol_msg(const std::string &dest_key, MsgType type,
			const uint8_t *payload = nullptr, int payload_len = 0);
	void _send_to_key(const std::string &dest_key,
			const uint8_t *data, int data_len);
	void _send_to_key_unreliable(const std::string &dest_key,
			const uint8_t *data, int data_len);

	// Logging helpers - prefix with [SERVER] or [CLIENT #id]
	String _log_prefix() const;
	void _log(const String &msg) const;
	void _log_dbg(const String &msg) const;
	void _log_err(const String &msg) const;

	// Inject Listen URI from project setting into config JSON
	String _inject_listen_scheme(const String &config_json);

	// Start the yggdrasil node with given config
	int _start_node(const String &config_json);
	void _stop_node();

	// Helper: write/read big-endian uint32 (used in protocol messages)
	static void write_u32_be(uint8_t *dst, uint32_t val);
	static uint32_t read_u32_be(const uint8_t *src);

protected:
	static void _bind_methods();

public:
	YggdrasilPeer();
	~YggdrasilPeer();

	// Public API for GDScript
	Error create_host(const String &config_json = "{}");
	Error create_client(const String &server_identity, const String &config_json = "{}");
	Error create_relay(const String &config_json = "{}");
	String get_yggdrasil_address() const;
	String get_yggdrasil_public_key() const;
	String start_listener(const String &uri);
	Error add_yggdrasil_peer(const String &uri);
	Error remove_yggdrasil_peer(const String &uri);
	String get_peers_info() const;
	String get_sessions_info() const;
	String get_yggdrasil_version() const;
	int get_yggdrasil_mtu() const;
	bool is_yggdrasil_server() const;
	void set_debug_logging(bool p_enable);
	bool get_debug_logging() const;

	// Routing state — exposed to GDScript
	bool has_route(const String &peer_key_hex) const;
	int get_routing_entries() const;
	int get_tree_entries() const;

	// Benchmark helpers — exposed to GDScript for latency measurement
	void benchmark_noop();
	int benchmark_noop_data(int size);

	// Raw C API access — bypass MultiplayerPeer protocol entirely.
	// create_bare() starts a ygg node without recv threads (for direct send_raw/recv_raw).
	// BLOCKING: recv_raw/recv_raw_unreliable block the calling thread until data or timeout.
	Error create_bare(const String &config_json = "{}");
	int send_raw(const String &dest_key_hex, const PackedByteArray &data);
	Dictionary recv_raw(int timeout_ms);
	int send_raw_unreliable(const String &dest_key_hex, const PackedByteArray &data);
	Dictionary recv_raw_unreliable(int timeout_ms);

	// MultiplayerPeerExtension overrides
	Error _get_packet(const uint8_t **r_buffer, int32_t *r_buffer_size) override;
	Error _put_packet(const uint8_t *p_buffer, int32_t p_buffer_size) override;
	int32_t _get_available_packet_count() const override;
	int32_t _get_max_packet_size() const override;

	int32_t _get_packet_channel() const override;
	MultiplayerPeer::TransferMode _get_packet_mode() const override;
	int32_t _get_packet_peer() const override;

	void _set_transfer_channel(int32_t p_channel) override;
	void _set_transfer_mode(MultiplayerPeer::TransferMode p_mode) override;
	int32_t _get_transfer_channel() const override;
	MultiplayerPeer::TransferMode _get_transfer_mode() const override;

	MultiplayerPeer::ConnectionStatus _get_connection_status() const override;
	int32_t _get_unique_id() const override;

	void _poll() override;
	void _close() override;
	void _disconnect_peer(int32_t p_peer, bool p_force) override;
	void _set_target_peer(int32_t p_peer) override;

	bool _is_server() const override;
	bool _is_server_relay_supported() const override;
	bool _is_refusing_new_connections() const override;
	void _set_refuse_new_connections(bool p_enable) override;
};

} // namespace godot

#endif // YGGDRASIL_PEER_H
