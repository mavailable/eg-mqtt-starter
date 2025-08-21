
from dataclasses import dataclass
from typing import Any, Dict
import asyncio
@dataclass
class Event:
    type: str
    data: Dict[str, Any]
class EventBus:
    def __init__(self):
        self.queue: asyncio.Queue[Event] = asyncio.Queue()
    async def publish(self, ev: Event):
        await self.queue.put(ev)
    def publish_threadsafe(self, loop: asyncio.AbstractEventLoop, ev: Event):
        loop.call_soon_threadsafe(self.queue.put_nowait, ev)
    async def next(self) -> Event:
        return await self.queue.get()
