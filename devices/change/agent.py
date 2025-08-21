
import os, asyncio, argparse
from datetime import datetime
from ..common.event_bus import EventBus
from ..common.input_keyboard import keyboard_task
from ..common.mqtt_helper import MqttClient
from ..common.io_gpio import AsyncButton
from ..common.identity import ensure_device_id

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "device_config.yaml"))
    parser.add_argument("--device-id", default=None)
    args = parser.parse_args()

    bus = EventBus()
    loop = asyncio.get_running_loop()
    kb = asyncio.create_task(keyboard_task(bus, "provision"))

    import yaml, json
    with open(args.config,"r") as f:
        raw_cfg = yaml.safe_load(f) or {}
    pins = (raw_cfg.get("pins") or {})

    allowed_ids = ["change-01"]
    agent_dir = os.path.dirname(__file__)
    device_id = await ensure_device_id(bus, loop, agent_dir, "change", allowed_ids, args.config, args.device_id, pins)
    print(f"[change] device_id = {device_id}")

    mq = MqttClient(client_id=device_id); mq.connect()

    sel_idx = 0; payouts = []; current_tag = None

    def on_connect(c,u,f,rc):
        print(f"[{device_id}] MQTT rc={rc}")
        mq.subscribe(mq.topic("dev","change-01","payouts"), qos=1)
        mq.subscribe(mq.topic("dev","change-01","res"), qos=1)

    def on_message(c,u,m):
        nonlocal payouts, sel_idx
        if m.topic.endswith("/payouts"):
            data = json.loads(m.payload.decode("utf-8"))
            payouts = data.get("items", [])
            if sel_idx >= len(payouts): sel_idx = max(0, len(payouts)-1)
            print(f"[change] payouts: {len(payouts)} items; selected index = {sel_idx}")
        else:
            print(f"[change] <- {m.topic} {m.payload.decode()}")

    mq.on_connect(on_connect); mq.on_message(on_message)

    if (pins.get("buttons") or {}).get("claim") is not None:
        AsyncButton(int(pins["buttons"]["claim"]), "claim", bus, loop)

    print("[change] CMD: r <UID> (scan), n/p (select), Enter/claim (credit), q (quit).")

    def claim_selected():
        nonlocal current_tag
        if not payouts:
            print("[change] no payout to claim."); return
        if not current_tag:
            print("[change] scan a tag first (r <UID>)"); return
        pid = payouts[sel_idx]["payout_id"]
        mq.publish(mq.topic("core","payouts","claim"), {
            "req_id": f"{device_id}-{datetime.utcnow().timestamp()}",
            "device_id": device_id, "payout_id": pid, "tag_uid": current_tag
        })

    while True:
        ev = await bus.next()
        if ev.type == "quit": break
        if ev.type == "rfid_scan":
            current_tag = ev.data["tag_uid"].upper(); print(f"[change] tag = {current_tag}")
        elif ev.type == "menu":
            key = ev.data.get("key")
            if key == "next" and payouts: sel_idx = (sel_idx + 1) % len(payouts); print(f"[change] select {sel_idx}")
            elif key == "prev" and payouts: sel_idx = (sel_idx - 1) % len(payouts); print(f"[change] select {sel_idx}")
            elif key == "ok": claim_selected()
        elif ev.type == "button":
            if ev.data.get("name")=="claim" and ev.data.get("edge")=="press": claim_selected()

if __name__ == "__main__":
    asyncio.run(main())
