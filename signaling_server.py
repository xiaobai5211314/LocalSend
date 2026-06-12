#!/usr/bin/env python3
"""LocalSend Signaling Server v0.3 - Python 3.6 compatible"""
import asyncio, json, time, hashlib, os, uuid, logging, sys, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

try:
    import websockets
except ImportError:
    print("ERROR: websockets not installed. Run: pip3 install websockets")
    sys.exit(1)

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger("ws")

UPLOAD_DIR = "/var/lib/localsend/uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

devices = {}

# ============================================================================
# WebSocket Handler
# ============================================================================

async def ws_handler(ws, path):
    did = None
    nm = "Unknown"
    remote = ws.remote_address
    log.info("WS CONNECT %s", remote)

    try:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except:
                continue
            t = data.get("type", "")

            if t == "register":
                nm = data.get("payload", {}).get("device_name", "Unknown")
                did = hashlib.sha256(("%s%s" % (nm, time.time())).encode()).hexdigest()[:12]
                devices[did] = {"name": nm, "ws": ws, "hb": time.time()}
                await ws.send(json.dumps({"type": "registered", "payload": {"device_id": did}}))
                log.info("REG %s=%s total=%d", nm, did, len(devices))
                await broadcast_device_list()

            elif t == "request_device_list":
                dl = [{"device_id": d, "device_name": devices[d]["name"]} for d in devices]
                await ws.send(json.dumps({"type": "device_list", "payload": {"devices": dl}}))

            elif t == "ping":
                if did in devices:
                    devices[did]["hb"] = time.time()
                await ws.send(json.dumps({"type": "pong"}))

            elif t in ("offer", "answer", "ice_candidate", "clipboard_update"):
                tg = data.get("to", "")
                if tg in devices:
                    try:
                        await devices[tg]["ws"].send(json.dumps(data))
                        log.info("FWD %s %s->%s", t, did, tg)
                    except Exception as e:
                        log.error("FWD %s FAIL: %s", t, e)
                else:
                    log.warning("FWD %s target %s not found", t, tg)

            elif t == "file_transfer":
                tg = data.get("to", "")
                payload = data.get("payload", {})
                log.info("FILE_TRANSFER from=%s(%s) to=%s file=%s size=%s url=%s",
                         did, nm, tg, payload.get("file_name", "?"),
                         payload.get("file_size", 0), payload.get("download_url", ""))
                data["from"] = did
                if tg in devices:
                    try:
                        await devices[tg]["ws"].send(json.dumps(data))
                        log.info("FILE_TRANSFER forwarded OK to %s", tg)
                    except Exception as e:
                        log.error("FILE_TRANSFER forward FAIL: %s", e)
                else:
                    log.warning("FILE_TRANSFER target %s not found", tg)
                    await ws.send(json.dumps({
                        "type": "file_transfer_error",
                        "from": tg, "to": did,
                        "payload": {
                            "transfer_id": payload.get("transfer_id", ""),
                            "file_name": payload.get("file_name", ""),
                            "error": "Target device %s not found" % tg
                        }
                    }))

            elif t == "file_transfer_ack":
                tg = data.get("to", "")
                payload = data.get("payload", {})
                data["from"] = did
                log.info("FILE_ACK from=%s(%s) to=%s file=%s tid=%s",
                         did, nm, tg, payload.get("file_name", "?"), payload.get("transfer_id", ""))
                if tg in devices:
                    try:
                        await devices[tg]["ws"].send(json.dumps(data))
                    except:
                        pass

            elif t == "file_transfer_error":
                tg = data.get("to", "")
                payload = data.get("payload", {})
                data["from"] = did
                log.info("FILE_ERROR from=%s(%s) to=%s err=%s",
                         did, nm, tg, payload.get("error", ""))
                if tg in devices:
                    try:
                        await devices[tg]["ws"].send(json.dumps(data))
                    except:
                        pass

    except Exception as e:
        log.error("Handler error: %s", e)
    finally:
        if did and did in devices:
            del devices[did]
            log.info("UNREG %s(%s) total=%d", did, nm, len(devices))
            await broadcast_device_list()

async def broadcast_device_list():
    dl = [{"device_id": d, "device_name": devices[d]["name"]} for d in devices]
    msg = json.dumps({"type": "device_list", "payload": {"devices": dl}})
    for d in list(devices.values()):
        try:
            await d["ws"].send(msg)
        except:
            pass

async def heartbeat():
    while True:
        await asyncio.sleep(15)
        n = time.time()
        dead = [d for d, i in list(devices.items()) if n - i["hb"] > 45]
        for d in dead:
            del devices[d]
            log.info("HB_TIMEOUT %s", d)
        if dead:
            await broadcast_device_list()

# ============================================================================
# HTTP Relay Server (port 9001)
# ============================================================================

class HTTPHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        log.info("HTTP %s", format % args)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ok", "service": "localsend-signaling",
                "version": "0.3.0", "devices": len(devices)
            }).encode())
        elif parsed.path.startswith("/download/"):
            file_id = parsed.path[len("/download/"):]
            file_path = os.path.join(UPLOAD_DIR, file_id)
            if os.path.exists(file_path):
                size = os.path.getsize(file_path)
                log.info("DOWNLOAD file_id=%s size=%d", file_id, size)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                with open(file_path, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                os.remove(file_path)
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"File not found")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/upload":
            content_length = int(self.headers.get("Content-Length", 0))
            content_type = self.headers.get("Content-Type", "")

            if "multipart/form-data" in content_type:
                boundary = content_type.split("boundary=")[1].encode()
                body = self.rfile.read(content_length)
                parts = body.split(b"--" + boundary)
                file_data = None
                for part in parts:
                    if b"filename=" in part:
                        header_end = part.find(b"\r\n\r\n")
                        if header_end != -1:
                            file_data = part[header_end+4:]
                            if file_data.endswith(b"\r\n"):
                                file_data = file_data[:-2]
            else:
                file_data = self.rfile.read(content_length)

            if file_data:
                file_id = str(uuid.uuid4())
                file_path = os.path.join(UPLOAD_DIR, file_id)
                with open(file_path, "wb") as f:
                    f.write(file_data)
                log.info("UPLOAD file_id=%s size=%d", file_id, len(file_data))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "file_id": file_id, "size": len(file_data)
                }).encode())
            else:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'{"error":"no file"}')
        else:
            self.send_response(404)
            self.end_headers()

def run_http_server():
    server = HTTPServer(("0.0.0.0", 9001), HTTPHandler)
    log.info("HTTP relay on 0.0.0.0:9001")
    server.serve_forever()

# ============================================================================
# Main
# ============================================================================

def main():
    # Start HTTP server in a thread
    http_thread = threading.Thread(target=run_http_server, daemon=True)
    http_thread.start()

    # Start WebSocket server
    loop = asyncio.get_event_loop()
    loop.create_task(heartbeat())

    start_server = websockets.serve(ws_handler, "0.0.0.0", 9000)
    log.info("WebSocket on 0.0.0.0:9000")
    log.info("LocalSend Signaling Server v0.3.0 started")

    loop.run_until_complete(start_server)
    loop.run_forever()

if __name__ == "__main__":
    main()
