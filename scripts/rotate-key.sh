#!/bin/bash
# #314: "generate new key" fallback for the #303 recover-connection flow.
#
# When the deployed server.yaml is unreadable/unparseable, the read-only
# recovery (#303, SSHRunner.recoverConfigScript) cannot extract the key or
# params. This script repairs the server instead of failing: it rotates
# ~/.olcrtc_key, rewrites server.yaml exactly the way scripts/srv.sh writes
# it, restarts the container so the new key takes effect, and prints the same
# machine-readable OLCRTC_URI= / OLCRTC_CONTAINER= lines srv.sh emits, so the
# iOS app reuses SSHRunner.parseInstallResult unchanged.
#
# It is uploaded over SSH the same way srv.sh is (base64-encoded printf, see
# SSHRunner.rotateKey) and driven by env vars:
#   OLCRTC_CONTAINER    — required; the olcrtc-server-* container to repair
#   OLCRTC_CONFIG_NAME  — optional; URI $-tail marker (default auto-provisioned)
#
# A NEW key is always generated (this is a rotation — srv.sh's "load existing
# key" branch is intentionally not copied). Carrier/transport/room/DNS/SOCKS
# and vp8/sei tuning are salvaged from the old server.yaml where readable and
# fall back to srv.sh's own defaults otherwise; videochannel tuning always
# falls back to defaults (not exposed in the app UI, same as install).
#
# srv.sh parity: blocks copied verbatim from scripts/srv.sh are wrapped in
# `# boc srv.sh` / `# eoc srv.sh` markers. Tests/RotateKeyScriptTests.swift
# verifies every non-comment line inside those markers still appears verbatim
# (whitespace-trimmed) in scripts/srv.sh, so the two cannot drift silently.
# scripts/srv.sh itself is parity-checked against upstream by parity_check.py.

set -e

CONTAINER_NAME="${OLCRTC_CONTAINER:?OLCRTC_CONTAINER is required}"

if ! podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" 2>/dev/null; then
    echo "[X] Container ${CONTAINER_NAME} not found"
    exit 1
fi

# Locate the deploy dir through the container's bind mount — same strategy as
# SSHRunner.reconfigureScript / recoverConfigScript (#303). Named WORK_DIR so
# the verbatim srv.sh lines below ("Generate YAML config") apply unchanged.
WORK_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${CONTAINER_NAME}")
if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "[X] Deploy dir not found for ${CONTAINER_NAME}"
    exit 1
fi

# boc srv.sh: deployed config path — srv.sh "Generate YAML config" section
CONFIG_FILE="$WORK_DIR/server.yaml"
# eoc srv.sh

# --- Salvage what is still readable from the old server.yaml ----------------
# srv.sh writes a flat 2-space-indented file; string scalars double-quoted,
# ints bare. Best-effort: empty when the file or the line is unreadable.
# (sed errors are discarded; `head` keeps the pipeline exit status 0.)
yaml_str() { sed -n "s/^  $1: \"\(.*\)\"\$/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1; }
yaml_int() { sed -n "s/^  $1: \([0-9][0-9]*\)\$/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1; }

CARRIER=$(yaml_str provider)
TRANSPORT=$(yaml_str transport)
ROOM_ID=$(yaml_str id)
DNS=$(yaml_str dns)
SOCKS_PROXY_ADDR=$(yaml_str proxy_addr)
SOCKS_PROXY_PORT=$(yaml_int proxy_port)

# Fall back to srv.sh's own defaults (the values it uses when the OLCRTC_*
# env vars are unset) for anything unreadable.
[ -n "$CARRIER" ]   || { CARRIER="jitsi";         echo "[!] carrier unreadable in $CONFIG_FILE — defaulting to $CARRIER"; }
[ -n "$TRANSPORT" ] || { TRANSPORT="datachannel"; echo "[!] transport unreadable in $CONFIG_FILE — defaulting to $TRANSPORT"; }
[ -n "$DNS" ]       || DNS="77.88.8.8:53"
[ -n "$SOCKS_PROXY_PORT" ] || SOCKS_PROXY_PORT=0

if [ -z "$ROOM_ID" ]; then
    if [ "$CARRIER" = "jitsi" ]; then
# boc srv.sh: Jitsi base URL handling — srv.sh OLCRTC_ROOM_ID env patch
    JITSI_BASE="${OLCRTC_JITSI_URL:-https://meet1.arbitr.ru}"
    JITSI_BASE="${JITSI_BASE%/}"
# eoc srv.sh
        # Same generated-room shape as srv.sh ("$JITSI_BASE/olcrtc-$PODMAN_ID").
        NEW_ID=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
        ROOM_ID="$JITSI_BASE/olcrtc-$NEW_ID"
        echo "[!] room unreadable — generated new Jitsi room: $ROOM_ID"
    else
        echo "[X] Room ID unreadable in $CONFIG_FILE and cannot be auto-generated for carrier '$CARRIER' — reinstall instead"
        exit 1
    fi
fi

# Transport tuning defaults, then salvage overrides for the active transport.
# boc srv.sh: transport-specific param defaults (srv.sh env-var patch block)
VIDEO_W="${OLCRTC_VIDEO_W:-1920}"; VIDEO_H="${OLCRTC_VIDEO_H:-1080}"
VIDEO_FPS="${OLCRTC_VIDEO_FPS:-30}"; VIDEO_BITRATE="${OLCRTC_VIDEO_BITRATE:-2M}"
VIDEO_HW="${OLCRTC_VIDEO_HW:-none}"; VIDEO_CODEC="${OLCRTC_VIDEO_CODEC:-qrcode}"
VIDEO_QR_SIZE="${OLCRTC_VIDEO_QR_SIZE:-0}"; VIDEO_QR_RECOVERY="${OLCRTC_VIDEO_QR_RECOVERY:-low}"
VIDEO_TILE_MODULE="${OLCRTC_VIDEO_TILE_MODULE:-4}"; VIDEO_TILE_RS="${OLCRTC_VIDEO_TILE_RS:-20}"
VP8_FPS="${OLCRTC_VP8_FPS:-25}"; VP8_BATCH="${OLCRTC_VP8_BATCH:-1}"
SEI_FPS="${OLCRTC_SEI_FPS:-60}"; SEI_BATCH="${OLCRTC_SEI_BATCH:-64}"
SEI_FRAG="${OLCRTC_SEI_FRAG:-900}"; SEI_ACK="${OLCRTC_SEI_ACK:-2000}"
# eoc srv.sh
# Only one transport block ever exists in an srv.sh-written file, so the flat
# fps/batch_size keys are unambiguous (same insight as parseRecoveredConfig).
if [ "$TRANSPORT" = "vp8channel" ]; then
    V=$(yaml_int fps);            [ -n "$V" ] && VP8_FPS="$V"
    V=$(yaml_int batch_size);     [ -n "$V" ] && VP8_BATCH="$V"
fi
if [ "$TRANSPORT" = "seichannel" ]; then
    V=$(yaml_int fps);            [ -n "$V" ] && SEI_FPS="$V"
    V=$(yaml_int batch_size);     [ -n "$V" ] && SEI_BATCH="$V"
    V=$(yaml_int fragment_size);  [ -n "$V" ] && SEI_FRAG="$V"
    V=$(yaml_int ack_timeout_ms); [ -n "$V" ] && SEI_ACK="$V"
fi

echo "[*] Repairing ${CONTAINER_NAME}: carrier=$CARRIER transport=$TRANSPORT room=$ROOM_ID"

# --- Rotate the encryption key -----------------------------------------------
# boc srv.sh: key validation helper (verbatim)
validate_key() {
    case "$1" in
        *[!0-9a-fA-F]*)
            return 1
            ;;
    esac
    [ "${#1}" -eq 64 ]
}
# eoc srv.sh

# boc srv.sh: new-key generation — srv.sh's "Generating new encryption key"
# branch, dedented (it sits inside an if/else there). Always taken here:
# rotation must NOT reuse the existing ~/.olcrtc_key.
KEY_FILE="$HOME/.olcrtc_key"
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
# eoc srv.sh

if ! validate_key "$KEY"; then
    echo "[X] Generated key failed validation (openssl missing or broken?)"
    exit 1
fi

# --- Rewrite server.yaml exactly the way srv.sh writes it --------------------
# boc srv.sh: "Generate YAML config" section (verbatim)
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
# eoc srv.sh

# Restart so the new key/config take effect. Same mechanism and rationale as
# SSHRunner.reconfigureScript: the container CMD is `sh -c "./olcrtc
# server.yaml"`, so a plain restart re-reads the rewritten file — no need to
# re-run the full srv.sh install pipeline.
echo "[*] Restarting ${CONTAINER_NAME} so the new key takes effect..."
podman restart "$CONTAINER_NAME"

# --- Emit the resulting URI (same output contract as srv.sh) -----------------
# boc srv.sh: config-name marker + URI assembly + machine-readable lines
sub_configname="${OLCRTC_CONFIG_NAME:-auto-provisioned}"
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
echo "OLCRTC_URI=$OLC_URI"
echo "OLCRTC_CONTAINER=$CONTAINER_NAME"
# eoc srv.sh
