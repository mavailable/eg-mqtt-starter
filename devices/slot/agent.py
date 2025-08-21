
import os, asyncio, argparse
from datetime import datetime
from ..common.event_bus import EventBus
from ..common.input_keyboard import keyboard_task
from ..common.mqtt_helper import MqttClient
from ..common.io_gpio import AsyncButton, AsyncOutput
from ..common.rfid import RFIDReader
from ..common.identity import ensure_device_id

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "device_config.yaml"))
    parser.add_argument("--device-id", default=None)
    args = parser.parse_args()

    bus = EventBus()
    loop = asyncio.get_running_loop()
    kb = asyncio.create_task(keyboard_task(bus, "provision"))

    import yaml
    with open(args.config,"r") as f:
        raw_cfg = yaml.safe_load(f) or {}
    pins = (raw_cfg.get("pins") or {})

    allowed_ids = [f"slot-{i:02d}" for i in range(1,10)]
    agent_dir = os.path.dirname(__file__)
    device_id = await ensure_device_id(bus, loop, agent_dir, "slot", allowed_ids, args.config, args.device_id, pins)
    print(f"[slot] device_id = {device_id}")

    mq = MqttClient(client_id=device_id); mq.connect()
    mq.subscribe(mq.topic("dev", device_id, "res"), qos=1)
    mq.on_connect(lambda c,u,f,rc: print(f"[{device_id}] MQTT rc={rc}"))
    mq.on_message(lambda c,u,m: print(f"[{device_id}] <- {m.topic} {m.payload.decode()}"))

    btn_pin = (pins.get("buttons") or {}).get("bet")
    if btn_pin is not None: AsyncButton(int(btn_pin), "bet", bus, loop)
    lamp_pin = (pins.get("outputs") or {}).get("lamp")
    lamp = AsyncOutput(int(lamp_pin)) if lamp_pin is not None else None

    rfid = RFIDReader(bus, loop); rfid.start()

    tag_uid = None
    print("[slot] CMD: r <UID>, b (bet200), c (credit500), n/p/enter (menu), q")

    while True:
        ev = await bus.next()
        if ev.type == "quit": print("Bye."); break
        if ev.type == "rfid_scan":
            tag_uid = ev.data["tag_uid"].upper(); print(f"[slot] RFID {tag_uid}")
            mq.publish(mq.topic("core","wallet","get"), {"req_id": f"{device_id}-{datetime.utcnow().timestamp()}","device_id": device_id,"tag_uid": tag_uid})
            if lamp: lamp.on()
        elif ev.type == "button":
            if ev.data.get("name")=="bet" and ev.data.get("edge")=="press":
                if tag_uid:
                    mq.publish(mq.topic("core","wallet","debit"), {"req_id": f"{device_id}-{datetime.utcnow().timestamp()}","device_id": device_id,"tag_uid": tag_uid,"amount_cents":200,"reason":"slot_bet"})
        elif ev.type == "bet":
            if tag_uid:
                mq.publish(mq.topic("core","wallet","debit"), {"req_id": f"{device_id}-{datetime.utcnow().timestamp()}","device_id": device_id,"tag_uid": tag_uid,"amount_cents":ev.data["amount_cents"],"reason":"slot_bet"})
        elif ev.type == "credit":
            if tag_uid:
                mq.publish(mq.topic("core","wallet","credit"), {"req_id": f"{device_id}-{datetime.utcnow().timestamp()}","device_id": device_id,"tag_uid": tag_uid,"amount_cents":ev.data["amount_cents"],"reason":"slot_win"})

if __name__ == "__main__":
    asyncio.run(main())
