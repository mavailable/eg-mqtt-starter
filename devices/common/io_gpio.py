
import asyncio
from .event_bus import Event
try:
    from gpiozero import Button, OutputDevice
    _HAVE_GPIO = True
except Exception:
    _HAVE_GPIO = False
class AsyncButton:
    def __init__(self, pin: int, name: str, bus, loop):
        self.pin = pin; self.name = name; self.bus = bus; self.loop = loop
        if not _HAVE_GPIO:
            print(f"[GPIO] gpiozero not available; button {name} pin {pin} mocked."); self.btn = None; return
        self.btn = Button(pin, pull_up=True, bounce_time=0.05)
        self.btn.when_pressed = self._pressed
        self.btn.when_released = self._released
    def _pressed(self):
        self.loop.call_soon_threadsafe(asyncio.create_task, self.bus.publish(Event("button", {"name": self.name, "edge":"press"})))
    def _released(self):
        self.loop.call_soon_threadsafe(asyncio.create_task, self.bus.publish(Event("button", {"name": self.name, "edge":"release"})))
class AsyncOutput:
    def __init__(self, pin: int, active_high=True, initial=False):
        if not _HAVE_GPIO:
            self.dev=None; self.state=initial; print(f"[GPIO] output pin {pin} mocked."); return
        self.dev = OutputDevice(pin, active_high=active_high, initial_value=initial)
    def on(self):  self.dev.on() if self.dev else None
    def off(self): self.dev.off() if self.dev else None
