
import os, asyncio, yaml
from .event_bus import Event
DEFAULT_STATE_DIR = os.getenv("EG_STATE_DIR", None)
def state_path_for(agent_dir: str, device_kind: str) -> str:
    base = DEFAULT_STATE_DIR or os.path.join(agent_dir, "state")
    os.makedirs(base, exist_ok=True)
    return os.path.join(base, "device_state.yaml")
def load_state(path: str):
    if not os.path.exists(path): return {}
    try:
        with open(path,"r") as f: return (yaml.safe_load(f) or {})
    except Exception: return {}
def save_state(path: str, state: dict):
    tmp = path + ".tmp"
    with open(tmp,"w") as f: yaml.safe_dump(state, f, sort_keys=False)
    os.replace(tmp, path)
async def provision_device_id(bus, loop, agent_dir: str, device_kind: str, allowed_ids: list, gpio_pins: dict | None = None) -> str:
    state_file = state_path_for(agent_dir, device_kind)
    state = load_state(state_file)
    if state.get("device_id"): return state["device_id"]
    print(f"[provision] First start: choose {device_kind} device_id")
    idx = 0; print_menu(allowed_ids, idx)
    try:
        from .io_gpio import AsyncButton
        if gpio_pins and "buttons" in gpio_pins:
            btns = gpio_pins["buttons"]
            if "menu_prev" in btns: AsyncButton(int(btns["menu_prev"]), "menu_prev", bus, loop)
            if "menu_next" in btns: AsyncButton(int(btns["menu_next"]), "menu_next", bus, loop)
            if "menu_ok" in btns:   AsyncButton(int(btns["menu_ok"]),   "menu_ok",   bus, loop)
    except Exception as e: print("[provision] GPIO not available:", e)
    while True:
        ev = await bus.next()
        if ev.type == "menu":
            key = ev.data.get("key")
            if key == "next": idx = (idx + 1) % len(allowed_ids); print_menu(allowed_ids, idx)
            elif key == "prev": idx = (idx - 1) % len(allowed_ids); print_menu(allowed_ids, idx)
            elif key == "ok":
                selected = allowed_ids[idx]; print(f"[provision] Selected: {selected}")
                state["device_id"] = selected; save_state(state_file, state); return selected
        elif ev.type == "button":
            name = ev.data.get("name"); edge = ev.data.get("edge")
            if edge != "press": continue
            if name == "menu_prev": idx = (idx - 1) % len(allowed_ids); print_menu(allowed_ids, idx)
            elif name == "menu_next": idx = (idx + 1) % len(allowed_ids); print_menu(allowed_ids, idx)
            elif name == "menu_ok":
                selected = allowed_ids[idx]; print(f"[provision] Selected: {selected}")
                state["device_id"] = selected; save_state(state_file, state); return selected
def print_menu(allowed, idx):
    line = " | ".join([f"[{x}]" if i==idx else x for i,x in enumerate(allowed)])
    print(f">> {line}")
