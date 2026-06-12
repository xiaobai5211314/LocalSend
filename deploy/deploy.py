#!/usr/bin/env python3
"""
LocalSend Enhanced 一键部署脚本
通过 paramiko 将信令服务器 + TURN 服务器部署到远程服务器
"""
import paramiko
import os
import sys
import time
import tarfile
import io

# ---- Configuration ----
REMOTE_HOST = "101.132.143.168"
REMOTE_USER = "root"
REMOTE_PASS = "dabai521@"
REMOTE_PATH = "/opt/localsend-server"

TURN_USERNAME = "localsend_user"
TURN_PASSWORD = "LsTurn_2026_SecureP@ss"

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def ssh_exec(ssh, cmd, desc=""):
    """Execute a command on the remote server and print output."""
    if desc:
        print(f"\n>>> {desc}")
    print(f"    $ {cmd}")
    stdin, stdout, stderr = ssh.exec_command(cmd)
    out = stdout.read().decode()
    err = stderr.read().decode()
    exit_code = stdout.channel.recv_exit_status()
    if out.strip():
        print(f"    {out.strip()}")
    if err.strip() and exit_code != 0:
        print(f"    STDERR: {err.strip()}")
    if exit_code != 0 and exit_code != 1:  # 1 can be non-fatal (e.g., grep)
        print(f"    [exit code: {exit_code}]")
    return out, err, exit_code

def upload_file(sftp, local_path, remote_path):
    """Upload a single file."""
    print(f"    Upload: {os.path.basename(local_path)} -> {remote_path}")
    sftp.put(local_path, remote_path)

def create_remote_dir(sftp, remote_path):
    """Create directory on remote server (mkdir -p equivalent)."""
    dirs = remote_path.split('/')
    current = ''
    for d in dirs:
        if not d:
            current = '/'
            continue
        current = os.path.join(current, d).replace('\\', '/')
        try:
            sftp.stat(current)
        except FileNotFoundError:
            try:
                sftp.mkdir(current)
            except OSError:
                pass  # parent might not exist yet, but we're going top-down

def main():
    print("=" * 60)
    print("LocalSend Enhanced 服务器部署")
    print(f"目标: {REMOTE_USER}@{REMOTE_HOST}:{REMOTE_PATH}")
    print("=" * 60)

    # ---- Connect ----
    print("\n[1/6] 连接服务器...")
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(REMOTE_HOST, username=REMOTE_USER, password=REMOTE_PASS, timeout=15)
    print("    ✓ 连接成功")

    sftp = ssh.open_sftp()

    # ---- Create remote directory ----
    print("\n[2/6] 创建远程目录...")
    ssh_exec(ssh, f"mkdir -p {REMOTE_PATH}/signaling-server/src", "创建部署目录")
    print("    ✓ 目录就绪")

    # ---- Upload signaling server source ----
    print("\n[3/6] 上传信令服务器源码...")
    sig_dir = os.path.join(PROJECT_DIR, "signaling-server")
    upload_file(sftp, os.path.join(sig_dir, "Cargo.toml"), f"{REMOTE_PATH}/signaling-server/Cargo.toml")
    src_dir = os.path.join(sig_dir, "src")
    for f in os.listdir(src_dir):
        if f.endswith('.rs'):
            upload_file(sftp, os.path.join(src_dir, f), f"{REMOTE_PATH}/signaling-server/src/{f}")

    # Upload Dockerfile for signaling server
    upload_file(sftp, os.path.join(sig_dir, "Dockerfile"), f"{REMOTE_PATH}/signaling-server/Dockerfile")
    print("    ✓ 源码上传完成")

    # ---- Upload and template turnserver.conf ----
    print("\n[4/6] 上传 TURN 配置...")
    turn_conf_path = os.path.join(PROJECT_DIR, "turn-server", "turnserver.conf")
    with open(turn_conf_path, 'r') as f:
        turn_conf = f.read()
    # Replace ${TURN_USERNAME}:${TURN_PASSWORD} with actual values
    turn_conf = turn_conf.replace("${TURN_USERNAME}", TURN_USERNAME)
    turn_conf = turn_conf.replace("${TURN_PASSWORD}", TURN_PASSWORD)
    # Write to remote
    with sftp.open(f"{REMOTE_PATH}/turnserver.conf", 'w') as f:
        f.write(turn_conf)
    print(f"    ✓ turnserver.conf 已上传 (用户名: {TURN_USERNAME})")

    # ---- Create and upload docker-compose.yml ----
    print("\n[5/6] 创建 docker-compose.yml 并启动服务...")
    docker_compose = f"""version: '3.8'

services:
  # ---- Signaling Server (Rust WebSocket) ----
  signaling:
    build:
      context: ./signaling-server
      dockerfile: Dockerfile
    container_name: localsend-signaling
    restart: unless-stopped
    ports:
      - "9000:9000"
    environment:
      - RUST_LOG=info
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      - localsend-net

  # ---- TURN Server (coturn) ----
  coturn:
    image: coturn/coturn:4.6-alpine
    container_name: localsend-turn
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./turnserver.conf:/etc/coturn/turnserver.conf:ro
    command:
      - turnserver
      - -c
      - /etc/coturn/turnserver.conf
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  localsend-net:
    driver: bridge
"""
    with sftp.open(f"{REMOTE_PATH}/docker-compose.yml", 'w') as f:
        f.write(docker_compose)
    print("    ✓ docker-compose.yml 已上传")

    # ---- Install Docker if needed ----
    out, _, rc = ssh_exec(ssh, "docker --version 2>/dev/null", "检查 Docker")
    if rc != 0:
        print("    Docker 未安装，正在安装...")
        ssh_exec(ssh, "curl -fsSL https://get.docker.com | sh", "安装 Docker")
        ssh_exec(ssh, "systemctl enable docker && systemctl start docker", "启动 Docker")
    else:
        print(f"    ✓ Docker 已安装: {out.strip()}")

    # ---- Stop existing containers and start ----
    ssh_exec(ssh, f"cd {REMOTE_PATH} && docker compose down 2>/dev/null || true", "停止旧容器")
    ssh_exec(ssh, f"cd {REMOTE_PATH} && docker compose up -d --build", "构建并启动服务 (首次构建可能需要几分钟)")

    # ---- Wait and verify ----
    print("\n[6/6] 验证部署...")
    print("    等待服务启动...")
    time.sleep(5)

    ssh_exec(ssh, f"cd {REMOTE_PATH} && docker compose ps", "查看容器状态")

    # Check signaling server
    out, _, rc = ssh_exec(ssh, "curl -s -o /dev/null -w '%{http_code}' http://localhost:9000 2>/dev/null", "检查信令服务器")
    if "426" in out or "101" in out or "400" in out:
        print("    ✓ 信令服务器正常运行 (WebSocket 升级响应)")
    else:
        print(f"    ⚠ 信令服务器响应: {out.strip()}")

    # Check TURN server
    out, _, rc = ssh_exec(ssh, "ss -tlnp | grep 3478 2>/dev/null || netstat -tlnp | grep 3478 2>/dev/null", "检查 TURN 服务器")
    if "3478" in out:
        print("    ✓ TURN 服务器正在监听端口 3478")
    else:
        print(f"    ⚠ TURN 服务器端口检查: {out.strip()}")

    sftp.close()
    ssh.close()

    print("\n" + "=" * 60)
    print("✅ 部署完成！")
    print("=" * 60)
    print(f"\n端点:")
    print(f"  信令服务器 (WebSocket): ws://{REMOTE_HOST}:9000")
    print(f"  TURN 中继 (UDP+TCP):    turn:{REMOTE_HOST}:3478")
    print(f"\nTURN 凭证:")
    print(f"  用户名: {TURN_USERNAME}")
    print(f"  密码:   {TURN_PASSWORD}")
    print(f"\n日志查看:")
    print(f"  ssh {REMOTE_USER}@{REMOTE_HOST}")
    print(f"  cd {REMOTE_PATH} && docker compose logs -f")

if __name__ == "__main__":
    main()
