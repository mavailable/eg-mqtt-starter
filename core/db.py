import sqlite3, json, datetime, threading
class DB:
    def __init__(self, path: str):
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.Lock()
        self._init()
    def _init(self):
        with self.lock, self.conn:
            self.conn.executescript(open('/app/schema.sql','r').read())
    def now(self): return datetime.datetime.utcnow().isoformat(timespec="seconds")+"Z"
    def get_balance(self, tag_uid:str)->int:
        with self.lock, self.conn:
            r=self.conn.execute("SELECT balance_cents FROM wallets WHERE tag_uid=?", (tag_uid,)).fetchone()
            if not r:
                self.conn.execute("INSERT INTO wallets(tag_uid,balance_cents,updated_at) VALUES(?,?,?)",(tag_uid,0,self.now())); return 0
            return int(r["balance_cents"])
    def credit(self, tag_uid, amt, device_id, op):
        with self.lock, self.conn:
            bal=self.get_balance(tag_uid); nb=bal+int(amt)
            self.conn.execute("UPDATE wallets SET balance_cents=?, updated_at=? WHERE tag_uid=?", (nb,self.now(),tag_uid))
            self.log(op, device_id, tag_uid, amt, {"old":bal,"new":nb}); return nb
    def debit(self, tag_uid, amt, device_id, op):
        with self.lock, self.conn:
            bal=self.get_balance(tag_uid); amt=int(amt)
            if bal<amt: return None
            nb=bal-amt; self.conn.execute("UPDATE wallets SET balance_cents=?, updated_at=? WHERE tag_uid=?", (nb,self.now(),tag_uid))
            self.log(op, device_id, tag_uid, amt, {"old":bal,"new":nb}); return nb
    def log(self, op, device_id, tag_uid, amount, details):
        with self.lock, self.conn:
            self.conn.execute("INSERT INTO tx_log(ts,device_id,op,tag_uid,amount_cents,details) VALUES(?,?,?,?,?,?)",
                              (self.now(), device_id, op, tag_uid, amount if amount is not None else None, json.dumps(details)))
    def create_payout(self, payout_id, source, amount, meta):
        with self.lock, self.conn:
            r=self.conn.execute("SELECT payout_id FROM payouts WHERE payout_id=?", (payout_id,)).fetchone()
            if r: return
            self.conn.execute("INSERT INTO payouts(payout_id,source,amount_cents,status,meta,created_at) VALUES (?,?,?,?,?,?)",
                              (payout_id, source, amount, "ready", json.dumps(meta or {}), self.now()))
            self.log("payout_new", source, None, amount, {"payout_id":payout_id,"meta":meta})
    def list_ready_payouts(self):
        with self.lock, self.conn:
            return [dict(r) for r in self.conn.execute("SELECT payout_id,source,amount_cents FROM payouts WHERE status='ready' ORDER BY created_at ASC")]
    def claim_payout(self, payout_id, tag_uid, device_id):
        with self.lock, self.conn:
            r=self.conn.execute("SELECT payout_id,amount_cents,status FROM payouts WHERE payout_id=?", (payout_id,)).fetchone()
            if not r: return None, "not_found"
            if r["status"]!="ready": return None, "already_claimed"
            amt=int(r["amount_cents"])
            self.conn.execute("UPDATE payouts SET status='claimed', claimed_by_tag=?, claimed_at=? WHERE payout_id=?",(tag_uid,self.now(),payout_id))
            self.log("payout_claim", device_id, tag_uid, amt, {"payout_id":payout_id}); return amt,"ok"
    def get_mode(self):
        with self.lock, self.conn:
            r=self.conn.execute("SELECT value FROM kv WHERE key='mode'").fetchone()
            if not r: return "day"
            import json
            return json.loads(r["value"])["mode"]
    def set_mode(self, mode:str):
        with self.lock, self.conn:
            import json
            self.conn.execute("INSERT INTO kv(key,value) VALUES('mode',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (json.dumps({"mode":mode}),))
