# Yggdrasil Multiplayer Peer for Godot

A GDExtension that provides a `MultiplayerPeerExtension` backed by [Yggdrasil](https://yggdrasil-network.github.io/), enabling peer-to-peer multiplayer over the Yggdrasil mesh network.

What's the point of this?
- Zero hosting costs for games
- Session discovery can be done by the PROTOCOL. (multicast session discovery)
- Future: VOIP traffic can be done over tunnel
- Bypasses CGNAT horribleness, needing to forward port
- Uses IPV6 addressing internally
- Encrypted by default
- Supports QUIC protocol transport and TCP, this means you can essentially make QUIC "droppless" for game networking swapping from WiFi to 4G for example on outages.
- You can use micro-networks per-session so the number of players is the peer count on the network
- You can use a relay for all your players.

## Benchmark data:
```
Throughput Summary (60KB packets):
  Total          MB/s
  -----          ----
  1MB          129.22
  8MB          233.54
  32MB         302.03
  64MB         328.07
  128MB        330.81
  512MB        337.81
  1GB          336.94

Latency Summary (echo RTT, 100 pings):
  Hops            Avg RTT      Per-hop
  ----            -------      -------
  1             188.638µs     94.319µs
  2             167.677µs     41.919µs
  4             491.584µs     61.448µs
  8             586.865µs     36.679µs
  16            988.346µs     30.885µs
  64           3.562252ms      27.83µs
```

Stability notes:
- Connections need more work to resolve hop latency with the godot side, and also to implement unreliable transfer via QUIC.
- Crashes don't seem common but the network hanging is common if you use mutilple nodes in a chain, when you use nodes direct to each other via their address it seems to be ok.
- I've tested with netfox netbrawler demo and it works but eventually introduces overhead as the game progresses, I believe due to the missing support for QUIC Unreliable packets, but I cannot be sure of this until I have more unit tests.
- This is not production ready, yggdrasil is not even finished yet.
- Throughput on LAN is OK but not tested wider internet yet.
- RFC 9221 

## Supported Platforms

| Platform | Architecture |
|----------|-------------|
| macOS | universal (arm64 + x86_64) |
| Linux | x86_64 |
| Windows | x86_64 |
| Android | arm64 |
| iOS | arm64 |

## Prerequisites

- [Go 1.24+](https://go.dev/dl/)
- [Python 3](https://www.python.org/) + [SCons](https://scons.org/) (`pip install scons`)
- C/C++ toolchain (Xcode on macOS, GCC/MinGW on Linux/Windows)

## Building

Clone with submodules:

```bash
git clone --recursive https://github.com/RevoluPowered/yggdrasil-multiplayer-peer-godot.git
cd yggdrasil-multiplayer-peer-godot
```

Build (this builds both the Go static library and the GDExtension):

```bash
scons               # macOS universal debug (default)
scons target=template_release  # release build
scons platform=linux arch=x86_64
scons platform=windows arch=x86_64 use_mingw=yes
```

The build automatically:
1. Compiles `libyggdrasil.a` from the `yggdrasil-go` submodule
2. Builds the C++ GDExtension, statically linking the Go library
3. Deploys the result to `../netfox/addons/yggdrasil/bin/`

## Project Structure

```
.
├── SConstruct              # Build system (SCons)
├── yggdrasil_peer.gdextension
├── src/                    # C++ GDExtension source
│   ├── yggdrasil_peer.cpp
│   ├── yggdrasil_peer.h
│   └── register_types.cpp
├── godot-cpp/              # Submodule: Godot C++ bindings
├── yggdrasil-go/           # Submodule: Yggdrasil with C library support
│   └── contrib/lib/        # Go → C static library (libyggdrasil.a)
└── bin/                    # Build output (gitignored)
```

## Running Tests

```bash
cd yggdrasil-go
go test -v ./contrib/lib/
```
