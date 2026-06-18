#!/bin/bash

echo "ЕСЛИ У ВАС ЕСТЬ ПРОБЛЕМЫ - Я В КУРСЕ, ПРОЕКТ В БЕТЕ, ПО ПРОБЛЕМАМ В ЧАТ t.me/openlibrecommunity ИЛИ ВООБЩЕ НЕКУДА, ЖДИТЕ РЕЛИЗА"

set -e

PODMAN_ID=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
CONTAINER_NAME="olcrtc-server-$PODMAN_ID"
# boc olcrtc-ios: pin to upstream's `golang:1.26-alpine3.22` for reproducible
#   builds (avoids rolling-`1.26-alpine` drift). Keep this tag in sync with the
#   iOS app's readiness probe + deep-uninstall in SSHRunner.swift (#232).
IMAGE_NAME="docker.io/library/golang:1.26-alpine3.22"
# eoc olcrtc-ios
REPO_URL="https://github.com/openlibrecommunity/olcrtc.git"
# boc olcrtc-ios
# /tmp is cleared on VPS reboot, wiping the binary and making the container
# unrestartable. Use a persistent location under /opt — the FHS home for add-on
# packages, and the same parent as the control bot (/opt/olcrtc-bot) — so all
# olcrtc server-side artifacts sit together.
# #431 was: WORK_DIR="/root/olcrtc-deploy-$PODMAN_ID" (our earlier reboot-persistence
#   fix); relocated to /opt for FHS tidiness. Old /root dirs from prior installs are
#   swept by the cleanup below + uninstall.
WORK_DIR="/opt/olcrtc-deploy-$PODMAN_ID"
# eoc olcrtc-ios
# boc olcrtc-ios-rejected: upstream keeps WORK_DIR under /tmp — cleared on VPS reboot, wiping the binary; replaced by the /opt boc above
# WORK_DIR="/tmp/olcrtc-deploy-$PODMAN_ID"
# eoc olcrtc-ios-rejected
BRANCH="master"
NO_CACHE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --branch=*)
            BRANCH="${1#*=}"
            shift
            ;;
        --no-cache)
            NO_CACHE=1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo "=== OlcRTC Server Deployment Script ==="
echo ""
echo "[*] Using branch: $BRANCH"
echo ""

if ! command -v podman &> /dev/null; then
    echo "[!] Installing Podman..."

    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif command -v sudo &> /dev/null; then
        SUDO="sudo"
    elif command -v doas &> /dev/null; then
        SUDO="doas"
    else
        echo "[X] No sudo/doas found and not running as root. Cannot install podman."
        exit 1
    fi

    if command -v apt &> /dev/null; then
        echo "[*] Detected apt (Debian/Ubuntu)"
        $SUDO apt update
        $SUDO apt install -y podman
    elif command -v dnf &> /dev/null; then
        echo "[*] Detected dnf (Fedora/RHEL)"
        $SUDO dnf install -y podman
    elif command -v yum &> /dev/null; then
        echo "[*] Detected yum (CentOS/RHEL)"
        $SUDO yum install -y podman
    elif command -v pacman &> /dev/null; then
        echo "[*] Detected pacman (Arch)"
        $SUDO pacman -Sy --noconfirm podman
    else
        echo "[X] Unsupported package manager. Install podman manually."
        exit 1
    fi
fi

echo "[+] Using Podman"
echo ""
# boc olcrtc-ios: install git and openssl if missing
#   The upstream script only auto-installs podman; git and openssl are assumed
#   present. Some minimal VPS images lack them, so we install explicitly.
#   curl is NOT installed — the QR-download section that needed it is removed
#   in the boc patch below.
if command -v apt &> /dev/null; then
    apt-get install -y --no-install-recommends git openssl 2>/dev/null || true
elif command -v dnf &> /dev/null; then
    dnf install -y git openssl 2>/dev/null || true
elif command -v yum &> /dev/null; then
    yum install -y git openssl 2>/dev/null || true
fi
# eoc olcrtc-ios

validate_key() {
    case "$1" in
        *[!0-9a-fA-F]*)
            return 1
            ;;
    esac
    [ "${#1}" -eq 64 ]
}

# boc olcrtc-ios: replace interactive carrier selection with OLCRTC_CARRIER env var
#   jazz was removed upstream; default to jitsi (the new recommended carrier).
CARRIER="${OLCRTC_CARRIER:-jitsi}"
[ -n "$CARRIER" ] || { echo "[X] OLCRTC_CARRIER is required"; exit 1; }
# eoc olcrtc-ios

echo "[*] Using carrier: $CARRIER"
echo ""

# boc olcrtc-ios: replace interactive transport selection with OLCRTC_TRANSPORT env var
TRANSPORT="${OLCRTC_TRANSPORT:-datachannel}"
[ -n "$TRANSPORT" ] || { echo "[X] OLCRTC_TRANSPORT is required"; exit 1; }
# eoc olcrtc-ios

echo "[*] Using transport: $TRANSPORT"
echo ""

GEN_ROOM=0
# boc olcrtc-ios: replace interactive room prompts with env vars.
#   telemost / wbstream: OLCRTC_ROOM_ID is the room id and is required.
#   jitsi: rooms are URLs. OLCRTC_JITSI_URL is the base server (default
#     meet1.arbitr.ru); OLCRTC_ROOM_ID may be a full http(s) URL (used
#     verbatim), a short room name (prefixed with the base), or empty (a
#     random room is generated). Mirrors upstream's interactive Jitsi menu.
#   GEN_ROOM stays 0 (the gen.yaml path below is dead code kept for parity).
ROOM_ID="${OLCRTC_ROOM_ID:-}"
if [ "$CARRIER" = "jitsi" ]; then
    JITSI_BASE="${OLCRTC_JITSI_URL:-https://meet1.arbitr.ru}"
    JITSI_BASE="${JITSI_BASE%/}"
    case "$ROOM_ID" in
        http://*|https://*) : ;;
        "")  ROOM_ID="$JITSI_BASE/olcrtc-$PODMAN_ID"
             echo "[*] Generated Jitsi room URL: $ROOM_ID" ;;
        *)   ROOM_ID="$JITSI_BASE/$ROOM_ID" ;;
    esac
fi
[ -n "$ROOM_ID" ] || { echo "[X] OLCRTC_ROOM_ID is required"; exit 1; }
# eoc olcrtc-ios

echo ""
# boc olcrtc-ios: replace interactive DNS prompt with OLCRTC_DNS env var
DNS="${OLCRTC_DNS:-77.88.8.8:53}"
# Default differs from upstream's 8.8.8.8 on purpose: Yandex resolves reliably from
# RU VPS, and the iOS client always sends OLCRTC_DNS, so this default only affects
# manual curl-piped installs. parity_check.py is structural and won't flag the IP.
# eoc olcrtc-ios

echo ""
# boc olcrtc-ios: SOCKS5 egress proxy via env vars; default off (no prompt)
SOCKS_PROXY_ADDR="${OLCRTC_SOCKS_PROXY_ADDR:-}"
SOCKS_PROXY_PORT="${OLCRTC_SOCKS_PROXY_PORT:-0}"
if [ -n "$SOCKS_PROXY_ADDR" ]; then
    echo "[*] Will use SOCKS5 proxy: $SOCKS_PROXY_ADDR:$SOCKS_PROXY_PORT"
fi
# eoc olcrtc-ios

# boc olcrtc-ios: transport-specific params from env vars (no interactive prompts)
#   The iOS app always sends OLCRTC_VP8_* (Settings sliders, default 60/64 —
#   carrier-tested mobile-throughput values) and OLCRTC_SEI_* (install-sheet
#   steppers) when those transports are used, so the fallbacks below only
#   govern non-app (curl|sh) runs and track upstream's defaults.
#   videochannel params fall back to these defaults (deliberately not exposed
#   in the UI — #097).
#   #320 was: VP8_FPS=60 / VP8_BATCH=8 ("raised for mobile throughput") — the
#   app never hits these fallbacks (it always sends its own values), so they
#   are re-based onto upstream's post-CPU-reduction 25/1; no benchmark needed,
#   the mobile 60-fps default lives in SettingsStore, not here.
VIDEO_W="${OLCRTC_VIDEO_W:-1920}"; VIDEO_H="${OLCRTC_VIDEO_H:-1080}"
VIDEO_FPS="${OLCRTC_VIDEO_FPS:-30}"; VIDEO_BITRATE="${OLCRTC_VIDEO_BITRATE:-2M}"
VIDEO_HW="${OLCRTC_VIDEO_HW:-none}"; VIDEO_CODEC="${OLCRTC_VIDEO_CODEC:-qrcode}"
VIDEO_QR_SIZE="${OLCRTC_VIDEO_QR_SIZE:-0}"; VIDEO_QR_RECOVERY="${OLCRTC_VIDEO_QR_RECOVERY:-low}"
VIDEO_TILE_MODULE="${OLCRTC_VIDEO_TILE_MODULE:-4}"; VIDEO_TILE_RS="${OLCRTC_VIDEO_TILE_RS:-20}"
VP8_FPS="${OLCRTC_VP8_FPS:-25}"; VP8_BATCH="${OLCRTC_VP8_BATCH:-1}"
SEI_FPS="${OLCRTC_SEI_FPS:-60}"; SEI_BATCH="${OLCRTC_SEI_BATCH:-64}"
SEI_FRAG="${OLCRTC_SEI_FRAG:-900}"; SEI_ACK="${OLCRTC_SEI_ACK:-2000}"
# eoc olcrtc-ios
# boc olcrtc-ios-rejected: upstream's interactive carrier / Jitsi-server / room / transport menus and their prompt-time defaults — the iOS app installs non-interactively, every choice arrives as an OLCRTC_* env var (boc blocks above)
# echo "Select carrier:"
# echo "  1) jitsi"
# echo "  2) telemost"
# echo "  3) wbstream"
# read -p "Enter choice [1-3, default: 1]: " CARRIER_CHOICE
# case "$CARRIER_CHOICE" in
#     2)
#         CARRIER="telemost"
#         ;;
#     3)
#         CARRIER="wbstream"
#         ;;
#     *)
#         CARRIER="jitsi"
#         ;;
# esac
# echo "Select transport:"
# echo "  1) datachannel"
# echo "  2) videochannel"
# echo "  3) seichannel"
# echo "  4) vp8channel"
# read -p "Enter choice [1-4, default: 1]: " TRANSPORT_CHOICE
# case "$TRANSPORT_CHOICE" in
#     2)
#         TRANSPORT="videochannel"
#         ;;
#     3)
#         TRANSPORT="seichannel"
#         ;;
#     4)
#         TRANSPORT="vp8channel"
#         ;;
#     *)
#         TRANSPORT="datachannel"
#         ;;
# esac
#     echo "Выберите Jitsi-сервер (проверьте в браузере, какой работает в вашей сети):"
#     echo "  1) https://meet.small-dm.ru/"
#     echo "  2) https://meet1.arbitr.ru/"
#     echo "  3) https://meet.handyweb.org/"
#     echo "  4) Другой (ввести вручную)"
#     read -p "Введите номер [1-4, по умолчанию: 1]: " JITSI_SERVER_CHOICE
#     case "$JITSI_SERVER_CHOICE" in
#         2)
#             JITSI_BASE_URL="https://meet1.arbitr.ru"
#         3)
#             JITSI_BASE_URL="https://meet.handyweb.org"
#         4)
#             read -p "Введите URL Jitsi-сервера: " JITSI_BASE_INPUT
#             JITSI_BASE_URL="${JITSI_BASE_INPUT%/}"
#             if [ -z "$JITSI_BASE_URL" ]; then
#                 echo "[X] URL не может быть пустым"
#                 exit 1
#             fi
#             JITSI_BASE_URL="https://meet.small-dm.ru"
#     echo "Room options:"
#     echo "  1) Auto-generate new room (recommended)"
#     echo "  2) Use specific room name or URL"
#     read -p "Enter choice [1-2, default: 1]: " ROOM_CHOICE
#     case "$ROOM_CHOICE" in
#         2)
#             read -p "Enter Jitsi room name or URL: " JITSI_ROOM_INPUT
#             if [ -z "$JITSI_ROOM_INPUT" ]; then
#                 echo "[X] Jitsi room name/URL cannot be empty"
#                 exit 1
#             fi
#             case "$JITSI_ROOM_INPUT" in
#                 http://*|https://*|*/*)
#                     ROOM_ID="$JITSI_ROOM_INPUT"
#                     ;;
#                 *)
#                     ROOM_ID="$JITSI_BASE_URL/$JITSI_ROOM_INPUT"
#                     ;;
#             esac
#             JITSI_ROOM="olcrtc-$PODMAN_ID"
#             ROOM_ID="$JITSI_BASE_URL/$JITSI_ROOM"
#             echo "[*] Generated Jitsi room URL: $ROOM_ID"
#     read -p "Enter Room ID: " ROOM_ID
#         echo "[X] Room ID/URL cannot be empty"
# read -p "DNS server [default: 8.8.8.8:53]: " DNS_INPUT
# DNS=${DNS_INPUT:-8.8.8.8:53}
# read -p "Use SOCKS5 proxy for egress? (y/N): " USE_PROXY
# SOCKS_PROXY_ADDR=""
# SOCKS_PROXY_PORT=0
# if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
#     read -p "Enter SOCKS5 proxy address [default: 127.0.0.1]: " PROXY_ADDR_INPUT
#     SOCKS_PROXY_ADDR=${PROXY_ADDR_INPUT:-127.0.0.1}
#     read -p "Enter SOCKS5 proxy port [default: 1080]: " PROXY_PORT_INPUT
#     SOCKS_PROXY_PORT=${PROXY_PORT_INPUT:-1080}
# VIDEO_W=1920; VIDEO_H=1080; VIDEO_FPS=30; VIDEO_BITRATE="2M"; VIDEO_HW="none"
# VIDEO_CODEC="qrcode"; VIDEO_QR_SIZE=0; VIDEO_QR_RECOVERY="low"
# VIDEO_TILE_MODULE=4; VIDEO_TILE_RS=20
# VP8_FPS=25; VP8_BATCH=1
# SEI_FPS=60; SEI_BATCH=64; SEI_FRAG=900; SEI_ACK=2000
#     echo "--- Videochannel settings ---"
#     echo "Video codec:"
#     echo "  1) qrcode"
#     echo "  2) tile (requires 1080x1080)"
#     read -p "Enter choice [1-2, default: 1]: " VCODEC_CHOICE
#     case "$VCODEC_CHOICE" in
#         2)
#             VIDEO_CODEC="tile"
#             VIDEO_W=1080
#             VIDEO_H=1080
#             echo "[*] Tile codec selected - forcing 1080x1080"
#             read -p "Tile module size in pixels 1..270 [default: 4]: " VTILE_MOD_INPUT
#             VIDEO_TILE_MODULE=${VTILE_MOD_INPUT:-4}
#             read -p "Tile Reed-Solomon parity percent 0..200 [default: 20]: " VTILE_RS_INPUT
#             VIDEO_TILE_RS=${VTILE_RS_INPUT:-20}
#             VIDEO_CODEC="qrcode"
#             read -p "Video width [default: 1920]: " VW_INPUT
#             VIDEO_W=${VW_INPUT:-1920}
#             read -p "Video height [default: 1080]: " VH_INPUT
#             VIDEO_H=${VH_INPUT:-1080}
#             read -p "QR error correction (low/medium/high/highest) [default: low]: " VQREC_INPUT
#             VIDEO_QR_RECOVERY=${VQREC_INPUT:-low}
#             read -p "QR fragment size bytes [default: 0 (auto)]: " VQRSZ_INPUT
#             VIDEO_QR_SIZE=${VQRSZ_INPUT:-0}
#     read -p "Video FPS [default: 30]: " VFPS_INPUT
#     VIDEO_FPS=${VFPS_INPUT:-30}
#     read -p "Video bitrate [default: 2M]: " VBRT_INPUT
#     VIDEO_BITRATE=${VBRT_INPUT:-2M}
#     read -p "Hardware acceleration (none/nvenc) [default: none]: " VHW_INPUT
#     VIDEO_HW=${VHW_INPUT:-none}
#     echo "--- VP8channel settings ---"
#     read -p "VP8 FPS [default: 25]: " VP8FPS_INPUT
#     VP8_FPS=${VP8FPS_INPUT:-25}
#     read -p "VP8 batch size (frames per tick) [default: 1]: " VP8BATCH_INPUT
#     VP8_BATCH=${VP8BATCH_INPUT:-1}
#     echo "--- SEIchannel settings ---"
#     read -p "SEI FPS [default: 60]: " SEIFPS_INPUT
#     SEI_FPS=${SEIFPS_INPUT:-60}
#     read -p "SEI batch size (frames per tick) [default: 64]: " SEIBATCH_INPUT
#     SEI_BATCH=${SEIBATCH_INPUT:-64}
#     read -p "SEI fragment size in bytes [default: 900]: " SEIFRAG_INPUT
#     SEI_FRAG=${SEIFRAG_INPUT:-900}
#     read -p "SEI ACK timeout in milliseconds [default: 2000]: " SEIACK_INPUT
#     SEI_ACK=${SEIACK_INPUT:-2000}
# eoc olcrtc-ios-rejected

echo ""
echo "[*] Cleaning workspace..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

CACHE_DIR="${OLCRTC_CACHE_DIR:-$HOME/.cache/olcrtc}"
GOMOD_CACHE="$CACHE_DIR/gomod"
GO_BUILD_CACHE="$CACHE_DIR/gobuild"

if [ "$NO_CACHE" = "1" ]; then
    echo "[*] --no-cache: purging Go cache at $CACHE_DIR"
    chmod -R u+w "$GOMOD_CACHE" "$GO_BUILD_CACHE" 2>/dev/null || true
    if ! rm -rf "$GOMOD_CACHE" "$GO_BUILD_CACHE" 2>/dev/null; then
        echo "[*] Falling back to in-container purge (files owned by container UID)..."
        podman run --rm \
            -v "$CACHE_DIR":/cache:Z \
            "$IMAGE_NAME" \
            sh -c 'rm -rf /cache/gomod /cache/gobuild'
    fi
fi

mkdir -p "$GOMOD_CACHE" "$GO_BUILD_CACHE"
echo "[*] Using Go cache: $CACHE_DIR"

echo "[*] Cloning repository..."
git clone --depth 1 --recurse-submodules --branch "$BRANCH" "$REPO_URL" "$WORK_DIR"

echo "[*] Pulling Go image..."
# boc olcrtc-ios: skip pull if image already cached — avoids Docker Hub
#   unauthenticated rate limits on repeated installs on the same VPS.
if podman image exists "$IMAGE_NAME" 2>/dev/null; then
    echo "[*] Image already cached, skipping pull"
else
    podman pull "$IMAGE_NAME"
fi
# eoc olcrtc-ios
# boc olcrtc-ios-rejected: upstream pulls the Go image unconditionally — replaced by the image-exists cache check above (Docker Hub unauthenticated rate limits)
# podman pull "$IMAGE_NAME"
# eoc olcrtc-ios-rejected

echo "[*] Building OlcRTC..."
podman run --rm \
    --network host \
    -v "$WORK_DIR":/app:Z \
    -v "$GOMOD_CACHE":/go/pkg/mod:Z \
    -v "$GO_BUILD_CACHE":/root/.cache/go-build:Z \
    -w /app \
    "$IMAGE_NAME" \
    sh -c "go mod download && go build -trimpath -ldflags='-s -w' -o olcrtc ./cmd/olcrtc"

if [ ! -f "$WORK_DIR/olcrtc" ]; then
    echo "[X] Build failed"
    exit 1
fi

if [ "$GEN_ROOM" = "1" ]; then
    echo "[*] Generating room via mode: gen..."
    GEN_CONFIG="$WORK_DIR/gen.yaml"
    cat > "$GEN_CONFIG" <<GENEOF
mode: gen
auth:
  provider: "$CARRIER"
net:
  dns: "$DNS"
gen:
  amount: 1
data: data
GENEOF
    ROOM_ID=$(podman run --rm \
        --network host \
        -v "$WORK_DIR":/app:Z \
        -w /app \
        "$IMAGE_NAME" \
        ./olcrtc gen.yaml)
    if [ -z "$ROOM_ID" ]; then
        echo "[X] Room generation failed"
        exit 1
    fi
    echo "[+] Generated room ID: $ROOM_ID"
fi

KEY_FILE="$HOME/.olcrtc_key"

if [ -f "$KEY_FILE" ]; then
    echo "[*] Loading existing encryption key..."
    KEY=$(tr -d '[:space:]' < "$KEY_FILE")
    if ! validate_key "$KEY"; then
        echo "[X] Invalid encryption key in $KEY_FILE"
        echo "    Remove the file to generate a new key, or replace it with 64 hex characters."
        exit 1
    fi
else
    echo "[*] Generating new encryption key..."
    KEY=$(openssl rand -hex 32)
    echo "$KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo ""
    echo "=========================================="
    echo "NEW ENCRYPTION KEY (saved to $KEY_FILE):"
    echo "$KEY"
    echo "=========================================="
    echo ""
fi

# Generate YAML config
CONFIG_FILE="$WORK_DIR/server.yaml"
cat > "$CONFIG_FILE" <<EOF
mode: srv
auth:
  provider: "$CARRIER"
room:
  id: "$ROOM_ID"
crypto:
  key: "$KEY"
net:
  transport: "$TRANSPORT"
  dns: "$DNS"
EOF

if [ -n "$SOCKS_PROXY_ADDR" ]; then
    cat >> "$CONFIG_FILE" <<EOF
socks:
  proxy_addr: "$SOCKS_PROXY_ADDR"
  proxy_port: $SOCKS_PROXY_PORT
EOF
fi

if [ "$TRANSPORT" = "vp8channel" ]; then
    cat >> "$CONFIG_FILE" <<EOF
vp8:
  fps: $VP8_FPS
  batch_size: $VP8_BATCH
EOF
fi

if [ "$TRANSPORT" = "seichannel" ]; then
    cat >> "$CONFIG_FILE" <<EOF
sei:
  fps: $SEI_FPS
  batch_size: $SEI_BATCH
  fragment_size: $SEI_FRAG
  ack_timeout_ms: $SEI_ACK
EOF
fi

if [ "$TRANSPORT" = "videochannel" ]; then
    cat >> "$CONFIG_FILE" <<EOF
video:
  width: $VIDEO_W
  height: $VIDEO_H
  fps: $VIDEO_FPS
  bitrate: "$VIDEO_BITRATE"
  hw: $VIDEO_HW
  codec: $VIDEO_CODEC
  qr_size: $VIDEO_QR_SIZE
  qr_recovery: $VIDEO_QR_RECOVERY
  tile_module: $VIDEO_TILE_MODULE
  tile_rs: $VIDEO_TILE_RS
EOF
fi

cat >> "$CONFIG_FILE" <<EOF
data: data
debug: false
EOF

echo "[*] Starting OlcRTC server..."
START_CMD="./olcrtc server.yaml"
if [ "$TRANSPORT" = "videochannel" ]; then
    START_CMD="apk add --no-cache ffmpeg >/dev/null && ./olcrtc server.yaml"
fi
# boc olcrtc-ios: drop any prior olcrtc-server-* container so a re-install on the
# same host replaces it instead of accumulating (the iOS app tracks one per host).
# #429: also remove superseded work dirs. WORK_DIR persists (now under /opt — see
# above) so each deploy's dir would otherwise pile up one-per-install. The containers
# that held those dirs were just removed, so they are now unreferenced; the freshly
# built $WORK_DIR is excluded by name. /root and /tmp are swept too for legacy
# installs that predate the /opt (#431) and /root moves.
OLD_CONTAINERS=$(podman ps -aq --filter "name=olcrtc-server-" 2>/dev/null)
[ -n "$OLD_CONTAINERS" ] && podman rm -f $OLD_CONTAINERS >/dev/null 2>&1 || true
find /opt /root /tmp -maxdepth 1 -type d -name 'olcrtc-deploy-*' \
    ! -name "olcrtc-deploy-$PODMAN_ID" -exec rm -rf {} + 2>/dev/null || true
# eoc olcrtc-ios
podman run -d \
    --network host \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -v "$WORK_DIR":/app:Z \
    -w /app \
    "$IMAGE_NAME" \
    sh -c "$START_CMD"

# boc olcrtc-ios: use env var for config name; skip interactive prompt.
#   Default "auto-provisioned" marks iOS-app installs; the app also sends
#   OLCRTC_CONFIG_NAME explicitly. Keep this literal in sync with
#   SSHRunner.installEnv (OLCRTC_CONFIG_NAME=auto-provisioned).
#   Naming note (#090): client-side this same value is the "mimo" field — the
#   `$`-tail of olcrtc:// URIs (App/Models/OlcrtcURI.swift). Same thing, two names.
sub_configname="${OLCRTC_CONFIG_NAME:-auto-provisioned}"
# eoc olcrtc-ios
# boc olcrtc-ios-rejected: upstream prompts for the config comment — comes in as OLCRTC_CONFIG_NAME (boc above)
# read -p "Enter a comment for the config (default: olc - t.me/openlibrecommunity): " sub_configname
# if [ -z "$sub_configname" ]; then
#     sub_configname="olc - t.me/openlibrecommunity"
# eoc olcrtc-ios-rejected

echo ""
echo "[+] Server started successfully!"
echo ""
echo "Container name: $CONTAINER_NAME"
echo "Carrier:        $CARRIER"
echo "Transport:      $TRANSPORT"
echo "Room ID/URL:    $ROOM_ID"
echo "Encryption key: $KEY"
echo ""
TRANSPORT_PAYLOAD=""
if [ "$TRANSPORT" = "vp8channel" ]; then
    TRANSPORT_PAYLOAD="<vp8-fps=${VP8_FPS}&vp8-batch=${VP8_BATCH}>"
elif [ "$TRANSPORT" = "seichannel" ]; then
    TRANSPORT_PAYLOAD="<fps=${SEI_FPS}&batch=${SEI_BATCH}&frag=${SEI_FRAG}&ack-ms=${SEI_ACK}>"
elif [ "$TRANSPORT" = "videochannel" ]; then
    TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-bitrate=${VIDEO_BITRATE}&video-hw=${VIDEO_HW}&video-codec=${VIDEO_CODEC}>"
    if [ "$VIDEO_CODEC" = "tile" ]; then
        TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-bitrate=${VIDEO_BITRATE}&video-hw=${VIDEO_HW}&video-codec=${VIDEO_CODEC}&video-tile-module=${VIDEO_TILE_MODULE}&video-tile-rs=${VIDEO_TILE_RS}>"
    elif [ "$VIDEO_QR_SIZE" -gt 0 ] 2>/dev/null; then
        TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-bitrate=${VIDEO_BITRATE}&video-hw=${VIDEO_HW}&video-codec=${VIDEO_CODEC}&video-qr-recovery=${VIDEO_QR_RECOVERY}&video-qr-size=${VIDEO_QR_SIZE}>"
    else
        TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-bitrate=${VIDEO_BITRATE}&video-hw=${VIDEO_HW}&video-codec=${VIDEO_CODEC}&video-qr-recovery=${VIDEO_QR_RECOVERY}>"
    fi
fi

OLC_URI="olcrtc://$CARRIER?${TRANSPORT}${TRANSPORT_PAYLOAD}@$ROOM_ID#$KEY\$$sub_configname"
echo "uri: $OLC_URI"
echo ""
# boc olcrtc-ios: emit machine-readable lines for app parsing
echo "OLCRTC_URI=$OLC_URI"
echo "OLCRTC_CONTAINER=$CONTAINER_NAME"
# eoc olcrtc-ios

# boc olcrtc-ios-rejected: upstream downloads the third-party gr binary to print a QR code — the iOS app renders its own QR from the URI; fetching an unpinned binary onto the VPS is an avoidable supply-chain risk
# GR_BIN="$WORK_DIR/gr"
# OS=$(uname -s | tr '[:upper:]' '[:lower:]')
# ARCH=$(uname -m)
# case "$ARCH" in
#     x86_64) ARCH="amd64" ;;
#     aarch64|arm64) ARCH="arm64" ;;
# esac
# GR_URL="https://github.com/zarazaex69/gr/releases/latest/download/gr-${OS}-${ARCH}"
# if curl -fsSL "$GR_URL" -o "$GR_BIN" 2>/dev/null; then
#     chmod +x "$GR_BIN"
#     echo "[*] QR code for your URI (scan with olcbox):"
#     "$GR_BIN" -o -s "$OLC_URI" 2>/dev/null || echo "[!] QR generation failed"
#     echo "[!] Could not download gr ($GR_URL), skipping QR"
# eoc olcrtc-ios-rejected

if [ -n "$SOCKS_PROXY_ADDR" ]; then
    echo "SOCKS5 proxy:   $SOCKS_PROXY_ADDR:$SOCKS_PROXY_PORT"
fi

echo ""
echo "View logs:"
echo "  podman logs -f $CONTAINER_NAME"
echo ""
echo "Stop server:"
echo "  podman stop $CONTAINER_NAME"
echo ""
