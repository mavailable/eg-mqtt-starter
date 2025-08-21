
import asyncio
from .event_bus import Event
HELP = "Clavier: 'r <UID>' (RFID), 'b' (bet 200), 'c' (credit 500), 'g <amount>' (payout), 'k <name>' (btn), 'n/p' (menu +/-), 'enter' (ok), 'q'"
async def keyboard_task(bus, device_id: str):
    print(HELP)
    while True:
        line = await asyncio.to_thread(input, "")
        s=line.strip()
        if s=="" or s.lower()=="enter":
            await bus.publish(Event("menu", {"key":"ok"})); continue
        if s=="q":
            await bus.publish(Event("quit", {"device_id": device_id})); break
        if s=="b":
            await bus.publish(Event("bet", {"device_id": device_id, "amount_cents":200}))
        elif s=="c":
            await bus.publish(Event("credit", {"device_id": device_id, "amount_cents":500}))
        elif s=="n":
            await bus.publish(Event("menu", {"key":"next"}))
        elif s=="p":
            await bus.publish(Event("menu", {"key":"prev"}))
        elif s.startswith("g "):
            try:
                _, amt = s.split(" ",1); amt=int(amt)
                await bus.publish(Event("gen_payout", {"amount_cents": amt}))
            except: print("Format: g <amount>")
        elif s.startswith("r "):
            _, uid = s.split(" ",1)
            await bus.publish(Event("rfid_scan", {"device_id": device_id, "tag_uid": uid.strip().upper()}))
        elif s.startswith("k "):
            _, name = s.split(" ",1)
            await bus.publish(Event("button", {"device_id": device_id, "name": name, "edge":"press"}))
        else:
            print(HELP)
