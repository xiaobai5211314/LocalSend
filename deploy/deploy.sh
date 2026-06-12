#!/usr/bin/env bash
# ============================================================================
# LocalSend 二开项目部署脚本
# 将信令服务器 + TURN 服务器部署到 101.132.143.168
# ============================================================================

set -euo pipefail

# ---- Configuration (override via .env) ----
REMOTE_HOST="${REMOTE_HOST:-101.132.143.168}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PATH="${REMOTE_PATH:-/opt/localsend-server}"
SSH_KEY="${SSH_KEY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---- Load .env if exists ----
if [ -f "$SCRIPT_DIR/.env" ]; then
    log_info "Loading environment from .env"
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
else
    log_warn ".env file not found. Using defaults."
    log_warn "Copy env.example to .env and set your values."
fi

# ---- Build SSH arguments ----
SSH_ARGS="-o StrictHostKeyChecking=no"
SCP_ARGS="-o StrictHostKeyChecking=no"
if [ -n "$SSH_KEY" ]; then
    SSH_ARGS="$SSH_ARGS -i $SSH_KEY"
    SCP_ARGS="$SCP_ARGS -i $SSH_KEY"
fi

# ---- Step 1: Build signaling server binary ----
log_info "Step 1/5: Building signaling server (Rust)..."
cd "$PROJECT_DIR/signaling-server"
cargo build --release
log_info "Signaling server built successfully."

# ---- Step 2: Create remote directory ----
log_info "Step 2/5: Creating remote directory..."
ssh $SSH_ARGS "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ${REMOTE_PATH}"

# ---- Step 3: Upload files ----
log_info "Step 3/5: Uploading files to ${REMOTE_HOST}..."
scp $SCP_ARGS \
    "$PROJECT_DIR/signaling-server/target/release/localsend-signaling" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

scp $SCP_ARGS \
    "$PROJECT_DIR/turn-server/turnserver.conf" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

scp $SCP_ARGS \
    "$SCRIPT_DIR/docker-compose.yml" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

# Create Dockerfile for signaling server
ssh $SSH_ARGS "${REMOTE_USER}@${REMOTE_HOST}" "cat > ${REMOTE_PATH}/Dockerfile.signaling << 'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY localsend-signaling /app/localsend-signaling
RUN chmod +x /app/localsend-signaling
EXPOSE 9000
CMD [\"/app/localsend-signaling\"]
EOF"

# Upload .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    scp $SCP_ARGS "$SCRIPT_DIR/.env" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/.env"
fi

log_info "Upload complete."

# ---- Step 4: Start services ----
log_info "Step 4/5: Starting services on remote host..."
ssh $SSH_ARGS "${REMOTE_USER}@${REMOTE_HOST}" << 'REMOTE_SCRIPT'
set -e

cd /opt/localsend-server

# Check if Docker and Docker Compose are installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# Load .env if exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# Stop existing containers
docker compose down 2>/dev/null || true

# Start containers
docker compose up -d

# Check status
sleep 2
docker compose ps

echo ""
echo "Services started:"
echo "  Signaling Server: ws://$(hostname -I | awk '{print $1}'):${SIGNALING_PORT:-9000}"
echo "  TURN Server:      turn:$(hostname -I | awk '{print $1}'):3478"
REMOTE_SCRIPT

# ---- Step 5: Verify ----
log_info "Step 5/5: Verifying deployment..."
sleep 3

# Check signaling server
SIGNALING_PORT="${SIGNALING_PORT:-9000}"
if ssh $SSH_ARGS "${REMOTE_USER}@${REMOTE_HOST}" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${SIGNALING_PORT}" 2>/dev/null | grep -q "426\|101\|400"; then
    log_info "Signaling server is responding (HTTP upgrade expected for WebSocket)."
else
    log_warn "Signaling server check returned unexpected response."
fi

log_info "============================================"
log_info "Deployment complete!"
log_info "============================================"
log_info ""
log_info "Endpoints:"
log_info "  Signaling (WebSocket): ws://${REMOTE_HOST}:${SIGNALING_PORT}"
log_info "  TURN (UDP+TCP):         turn:${REMOTE_HOST}:3478"
log_info ""
log_info "Logs:"
log_info "  ssh ${REMOTE_USER}@${REMOTE_HOST} 'docker compose -f ${REMOTE_PATH}/docker-compose.yml logs -f'"
