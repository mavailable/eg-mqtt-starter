
import os, json
import paho.mqtt.client as mqtt
class MqttClient:
    def __init__(self, client_id: str, ns: str = "eg", host: str | None = None, port: int | None = None):
        self.ns = ns
        self.host = host or os.getenv("BROKER_HOST","localhost")
        self.port = int(port or os.getenv("BROKER_PORT","1883"))
        self.client = mqtt.Client(client_id=client_id, clean_session=True)
        self.client.enable_logger()
    def connect(self, keepalive=30):
        self.client.connect(self.host, self.port, keepalive=keepalive)
        self.client.loop_start()
    def topic(self, *parts):
        return "/".join([self.ns] + list(parts))
    def subscribe(self, topic: str, qos=1):
        self.client.subscribe(topic, qos=qos)
    def on_message(self, fn): self.client.on_message = fn
    def on_connect(self, fn): self.client.on_connect = fn
    def publish(self, topic: str, payload: dict, qos=1, retain=False):
        s = json.dumps(payload, separators=(",",":"))
        self.client.publish(topic, s, qos=qos, retain=retain)
