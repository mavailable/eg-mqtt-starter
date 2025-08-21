#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "[setup] project dir = $ROOT"

mkdir -p "$ROOT/mosquitto" "$ROOT/data"
mkdir -p "$ROOT/core/web/react/slot/dist" \
         "$ROOT/core/web/react/change/dist" \
         "$ROOT/core/web/react/roulette/dist" \
         "$ROOT/core/web/react/blackjack/dist"

# ---------------- docker-compose.yml ----------------
cat > "$ROOT/docker-compose.yml" <<'YAML'
version: "3.8"
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: eg-mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
      - "9001:9001"
    volumes:
      - ./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - mosquitto_data:/mosquitto/data
      - mosquitto_log:/mosquitto/log

  core:
    build: ./core
    container_name: eg-core
    restart: unless-stopped
    environment:
      - BROKER_HOST=mosquitto
      - BROKER_PORT=1883
      - WS_PORT=9001
      - MQTT_NAMESPACE=eg
      - DB_PATH=/data/core.db
    depends_on:
      - mosquitto
    ports:
      - "8000:8000"
    volumes:
      - ./core:/app
      - ./data:/data

volumes:
  mosquitto_data:
  mosquitto_log:
YAML

# ---------------- mosquitto.conf ----------------
cat > "$ROOT/mosquitto/mosquitto.conf" <<'CFG'
listener 1883
protocol mqtt
listener 9001
protocol websockets

persistence true
persistence_location /mosquitto/data/

log_timestamp true
log_type error
log_type warning
log_type notice
log_type information

allow_anonymous true
CFG

# ---------------- core/Dockerfile ----------------
cat > "$ROOT/core/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn","core:app","--host","0.0.0.0","--port","8000"]
DOCKER

# ---------------- core/requirements.txt ----------------
cat > "$ROOT/core/requirements.txt" <<'REQ'
fastapi>=0.111.0
uvicorn>=0.30.0
paho-mqtt>=1.6.1
REQ

# ---------------- core/schema.sql ----------------
cat > "$ROOT/core/schema.sql" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS wallets (tag_uid TEXT PRIMARY KEY, balance_cents INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS payouts (payout_id TEXT PRIMARY KEY, source TEXT NOT NULL, amount_cents INTEGER NOT NULL, status TEXT NOT NULL, claimed_by_tag TEXT, meta TEXT, created_at TEXT NOT NULL, claimed_at TEXT);
CREATE TABLE IF NOT EXISTS tx_log (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, device_id TEXT NOT NULL, op TEXT NOT NULL, tag_uid TEXT, amount_cents INTEGER, details TEXT);
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
SQL

# ---------------- core/db.py ----------------
cat > "$ROOT/core/db.py" <<'PY'
import sqlite3, json, datetime, threading
class DB:
    def __init__(self, path: str):
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.Lock()
        self._init()
    def _init(self):
        with self.lock, self.conn:
            self.conn.executescript(open('/app/schema.sql','r').read())
    def now(self): return datetime.datetime.utcnow().isoformat(timespec="seconds")+"Z"
    def get_balance(self, tag_uid:str)->int:
        with self.lock, self.conn:
            r=self.conn.execute("SELECT balance_cents FROM wallets WHERE tag_uid=?", (tag_uid,)).fetchone()
            if not r:
                self.conn.execute("INSERT INTO wallets(tag_uid,balance_cents,updated_at) VALUES(?,?,?)",(tag_uid,0,self.now())); return 0
            return int(r["balance_cents"])
    def credit(self, tag_uid, amt, device_id, op):
        with self.lock, self.conn:
            bal=self.get_balance(tag_uid); nb=bal+int(amt)
            self.conn.execute("UPDATE wallets SET balance_cents=?, updated_at=? WHERE tag_uid=?", (nb,self.now(),tag_uid))
            self.log(op, device_id, tag_uid, amt, {"old":bal,"new":nb}); return nb
    def debit(self, tag_uid, amt, device_id, op):
        with self.lock, self.conn:
            bal=self.get_balance(tag_uid); amt=int(amt)
            if bal<amt: return None
            nb=bal-amt; self.conn.execute("UPDATE wallets SET balance_cents=?, updated_at=? WHERE tag_uid=?", (nb,self.now(),tag_uid))
            self.log(op, device_id, tag_uid, amt, {"old":bal,"new":nb}); return nb
    def log(self, op, device_id, tag_uid, amount, details):
        with self.lock, self.conn:
            self.conn.execute("INSERT INTO tx_log(ts,device_id,op,tag_uid,amount_cents,details) VALUES(?,?,?,?,?,?)",
                              (self.now(), device_id, op, tag_uid, amount if amount is not None else None, json.dumps(details)))
    def create_payout(self, payout_id, source, amount, meta):
        with self.lock, self.conn:
            r=self.conn.execute("SELECT payout_id FROM payouts WHERE payout_id=?", (payout_id,)).fetchone()
            if r: return
            self.conn.execute("INSERT INTO payouts(payout_id,source,amount_cents,status,meta,created_at) VALUES (?,?,?,?,?,?)",
                              (payout_id, source, amount, "ready", json.dumps(meta or {}), self.now()))
            self.log("payout_new", source, None, amount, {"payout_id":payout_id,"meta":meta})
    def list_ready_payouts(self):
        with self.lock, self.conn:
            return [dict(r) for r in self.conn.execute("SELECT payout_id,source,amount_cents FROM payouts WHERE status='ready' ORDER BY created_at ASC")]
    def claim_payout(self, payout_id, tag_uid, device_id):
        with self.lock, self.conn:
            r=self.conn.execute("SELECT payout_id,amount_cents,status FROM payouts WHERE payout_id=?", (payout_id,)).fetchone()
            if not r: return None, "not_found"
            if r["status"]!="ready": return None, "already_claimed"
            amt=int(r["amount_cents"])
            self.conn.execute("UPDATE payouts SET status='claimed', claimed_by_tag=?, claimed_at=? WHERE payout_id=?",(tag_uid,self.now(),payout_id))
            self.log("payout_claim", device_id, tag_uid, amt, {"payout_id":payout_id}); return amt,"ok"
    def get_mode(self):
        with self.lock, self.conn:
            r=self.conn.execute("SELECT value FROM kv WHERE key='mode'").fetchone()
            if not r: return "day"
            import json
            return json.loads(r["value"])["mode"]
    def set_mode(self, mode:str):
        with self.lock, self.conn:
            import json
            self.conn.execute("INSERT INTO kv(key,value) VALUES('mode',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (json.dumps({"mode":mode}),))
PY

# ---------------- core/core.py ----------------
cat > "$ROOT/core/core.py" <<'PY'
import os, json
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
import paho.mqtt.client as mqtt
from db import DB

BROKER_HOST=os.getenv("BROKER_HOST","localhost"); BROKER_PORT=int(os.getenv("BROKER_PORT","1883"))
NS=os.getenv("MQTT_NAMESPACE","eg"); DB_PATH=os.getenv("DB_PATH","/data/core.db")

app=FastAPI(title="EG Core",version="1.3.0"); app.mount("/web", StaticFiles(directory="/app/web", html=True), name="web")
db=DB(DB_PATH)
client=mqtt.Client(client_id="core-01", clean_session=True); client.enable_logger()

def T(*p): return "/".join([NS]+list(p))
def pub(t,p,qos=1,retain=False): client.publish(t, json.dumps(p,separators=(",",":")), qos=qos, retain=retain)

def on_connect(c,u,f,rc):
    c.subscribe(T("core","#"),qos=1); c.subscribe(T("night","vote"),qos=1)
    pub(T("state","mode"), {"mode": db.get_mode()}, qos=1, retain=True)

def on_message(c,u,msg):
    try: p=json.loads(msg.payload.decode("utf-8"))
    except: return
    if msg.topic==T("core","wallet","get"): wallet_get(p)
    elif msg.topic==T("core","wallet","debit"): wallet_debit(p)
    elif msg.topic==T("core","wallet","credit"): wallet_credit(p)
    elif msg.topic==T("core","payouts","new"): payout_new(p)
    elif msg.topic==T("core","payouts","claim"): payout_claim(p)
    elif msg.topic==T("night","vote"): vote(p)

def respond(dev_id, body): pub(T("dev",dev_id,"res"), body, qos=1, retain=False)

def wallet_get(p):
    r=p.get("req_id"); d=p.get("device_id"); tag=p.get("tag_uid","").upper()
    bal=db.get_balance(tag); db.log("wallet_get", d, tag, None, {"balance":bal})
    respond(d, {"req_id":r,"type":"wallet_get","status":"ok","balance_cents":bal})

def wallet_debit(p):
    r=p.get("req_id"); d=p.get("device_id"); tag=p.get("tag_uid","").upper(); amt=int(p.get("amount_cents",0))
    nb=db.debit(tag, amt, d, "wallet_debit")
    respond(d, {"req_id":r,"type":"wallet_debit","status":"ok" if nb is not None else "insufficient","new_balance_cents":nb})

def wallet_credit(p):
    r=p.get("req_id"); d=p.get("device_id"); tag=p.get("tag_uid","").upper(); amt=int(p.get("amount_cents",0))
    nb=db.credit(tag, amt, d, "wallet_credit")
    respond(d, {"req_id":r,"type":"wallet_credit","status":"ok","new_balance_cents":nb})

def payout_new(p):
    db.create_payout(p.get("payout_id"), p.get("source","unknown"), int(p.get("amount_cents",0)), p.get("meta",{}))
    pub(T("dev","change-01","payouts"), {"items": db.list_ready_payouts()}, qos=1, retain=False)

def payout_claim(p):
    r=p.get("req_id"); d=p.get("device_id"); tag=p.get("tag_uid","").upper(); pid=p.get("payout_id")
    amt,status=db.claim_payout(pid, tag, d)
    if status!="ok": respond(d, {"req_id":r,"type":"payout_claim","status":status}); return
    nb=db.credit(tag, int(amt), d, "payout_claim_credit")
    respond(d, {"req_id":r,"type":"payout_claim","status":"ok","credited_cents":int(amt),"new_balance_cents":nb})
    pub(T("dev","change-01","payouts"), {"items": db.list_ready_payouts()}, qos=1, retain=False)

_votes={}
def vote(p):
    step=str(p.get("step")); _votes.setdefault(step,{})[p.get("device_id")]=p.get("choice")
    db.log("vote", p.get("device_id","?"), None, None, p)

@app.post("/api/mode")
async def api_mode(req: Request):
    body=await req.json(); mode=body.get("mode","day"); db.set_mode(mode)
    pub(T("state","mode"), {"mode":mode}, qos=1, retain=True); return {"ok":True,"mode":mode}

@app.post("/api/night/step")
async def api_night_step(req: Request):
    body=await req.json(); pub(T("night","step"), body, qos=1, retain=False); return {"ok":True}

@app.get("/", response_class=HTMLResponse)
async def index():
    return '''<html><body>
<h1>EG Core</h1>
<ul>
  <li><a href="/web/react/slot/dist/index.html?device_id=slot-01">Slot</a></li>
  <li><a href="/web/react/change/dist/index.html">Change</a></li>
  <li><a href="/web/react/roulette/dist/index.html?device_id=roulette-01">Roulette</a></li>
  <li><a href="/web/react/blackjack/dist/index.html?device_id=blackjack-01">Blackjack</a></li>
</ul>
</body></html>'''

def start_mqtt():
    client.on_connect=on_connect; client.on_message=on_message
    client.connect(BROKER_HOST, BROKER_PORT, keepalive=30); client.loop_start()
start_mqtt()
PY

# ---------------- React placeholders ----------------
for app in slot change roulette blackjack; do
  echo "<!doctype html><html><body><h2>${app^} UI</h2><p>Build here.</p></body></html>" > "$ROOT/core/web/react/$app/dist/index.html"
done

echo "[setup] done. Next steps:"
echo "  cd $ROOT"
echo "  docker compose up --build -d"
