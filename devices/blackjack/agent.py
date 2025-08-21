
import os, asyncio, argparse, random
from datetime import datetime
from ..common.event_bus import EventBus
from ..common.input_keyboard import keyboard_task
from ..common.mqtt_helper import MqttClient
from ..common.io_gpio import AsyncButton
from ..common.identity import ensure_device_id

def new_id(prefix):
    return f"{prefix}-{int(datetime.utcnow().timestamp()*1000):x}"

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

    allowed_ids = ["blackjack-01"]
    agent_dir = os.path.dirname(__file__)
    device_id = await ensure_device_id(bus, loop, agent_dir, "blackjack", allowed_ids, args.config, args.device_id, pins)
    print(f"[blackjack] device_id = {device_id}")

    mq = MqttClient(client_id=device_id); mq.connect()
    mq.on_connect(lambda c,u,f,rc: print(f"[{device_id}] MQTT rc={rc}"))

    if (pins.get("buttons") or {}).get("payout") is not None:
        AsyncButton(int(pins["buttons"]["payout"]), "payout", bus, loop)

    print("[blackjack] CMD: g <amount> payout; 'b' -> 4000; GPIO 'payout' -> random payout; n/p/enter menu.")

    async def send_payout(amount:int):
        pid = new_id("p")
        mq.publish(mq.topic("core","payouts","new"), {
            "payout_id": pid,
            "source": "blackjack",
            "amount_cents": amount,
            "meta": {"hand": new_id("H")}
        })

    while True:
        ev = await bus.next()
        if ev.type == "quit": break
        if ev.type == "gen_payout": await send_payout(int(ev.data["amount_cents"]))
        elif ev.type == "bet": await send_payout(4000)
        elif ev.type == "button":
            if ev.data.get("name")=="payout" and ev.data.get("edge")=="press":
                await send_payout(random.choice([2000,4000,8000,16000]))

if __name__ == "__main__":
    asyncio.run(main())
