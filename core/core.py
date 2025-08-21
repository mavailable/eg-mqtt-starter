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
