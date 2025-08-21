
import os, yaml, asyncio
from .provisioning import provision_device_id, state_path_for, load_state, save_state
async def ensure_device_id(bus, loop, agent_dir: str, device_kind: str, allowed_ids: list, cfg_path: str | None, cli_device_id: str | None, gpio_pins: dict | None):
    if cli_device_id:
        persist(agent_dir, device_kind, cli_device_id); return cli_device_id
    sp = state_path_for(agent_dir, device_kind); st = load_state(sp)
    if st.get("device_id"): return st["device_id"]
    did = None
    if cfg_path and os.path.exists(cfg_path):
        try:
            with open(cfg_path,"r") as f: did = (yaml.safe_load(f) or {}).get("device_id")
        except Exception: pass
    if did: persist(agent_dir, device_kind, did); return did
    return await provision_device_id(bus, loop, agent_dir, device_kind, allowed_ids, gpio_pins)
def persist(agent_dir: str, device_kind: str, device_id: str):
    sp = state_path_for(agent_dir, device_kind); st = load_state(sp); st["device_id"]=device_id; save_state(sp, st); print(f"[identity] persisted {device_id} -> {sp}")
