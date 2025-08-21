
import threading, time
from .event_bus import Event
class RFIDReader:
    def __init__(self, bus, loop):
        self.bus = bus; self.loop = loop; self._stop=False; self._thread=None
        self._mode="mock"
        try:
            from mfrc522 import SimpleMFRC522  # type: ignore
            self.reader = SimpleMFRC522(); self._mode="simple"
        except Exception:
            try:
                import MFRC522  # type: ignore
                self.mfrc = MFRC522.MFRC522(); self._mode="lowlevel"
            except Exception:
                self.reader=None
    def start(self):
        self._stop=False; self._thread=threading.Thread(target=self._run, daemon=True); self._thread.start()
    def stop(self):
        self._stop=True
        if self._thread: self._thread.join(timeout=0.2)
    def _run(self):
        if self._mode=="simple": self._loop_simple()
        elif self._mode=="lowlevel": self._loop_lowlevel()
        else:
            print("[RFID] MOCK: use keyboard command 'r <UID>'")
            while not self._stop: time.sleep(0.5)
    def _loop_simple(self):
        print("[RFID] SimpleMFRC522 mode")
        while not self._stop:
            try:
                id_val, _ = self.reader.read()
                uid = f"{int(id_val):08X}"
                self.loop.call_soon_threadsafe(self.bus.queue.put_nowait, Event("rfid_scan", {"tag_uid": uid}))
            except Exception:
                time.sleep(0.3)
    def _loop_lowlevel(self):
        print("[RFID] MFRC522 low-level mode")
        while not self._stop:
            try:
                (status, TagType) = self.mfrc.MFRC522_Request(self.mfrc.PICC_REQIDL)
                if status == self.mfrc.MI_OK:
                    (status, uid) = self.mfrc.MFRC522_Anticoll()
                    if status == self.mfrc.MI_OK and uid:
                        uid_hex = "".join(f"{b:02X}" for b in uid[:5])
                        self.loop.call_soon_threadsafe(self.bus.queue.put_nowait, Event("rfid_scan", {"tag_uid": uid_hex}))
            except Exception:
                time.sleep(0.3)
