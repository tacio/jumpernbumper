#!/usr/bin/env python3
"""Comprehensive Phase 2 multi-client E2E test suite for Jumper 'n Bumper.

Tests the live SpacetimeDB v2.16.3 module over `v1.json.spacetimedb` WebSockets:
1. client_connected / Player creation / set_nickname validation & RoomMember sync
2. Public room browser & private room join-by-code (case-insensitive)
3. 4-player cap enforcement & slot selection / leaving / empty-room deletion
4. Host-only settings/start validation, ready-up requirement, & host migration on disconnect
5. Room lock when InProgress (late join rejected), live 30 Hz physics, head-stomp KillEvent,
   Kill Limit victory transition -> MatchBunny cleanup -> return_to_lobby rematch reset
6. InProgress disconnect dropping from 2 players down to 1 ends match cleanly
7. Time Limit (10s) match victory transition & idle MatchTickSchedule shutdown
"""

import asyncio
import json
import pathlib
import sys
import time
import websockets

DEFAULT_URL = "ws://127.0.0.1:3100/v1/database/jumpernbumper/subscribe"
SCHEMAS_PATH = pathlib.Path(__file__).resolve().parent.parent / "shared" / "table_schemas.json"

with SCHEMAS_PATH.open("r", encoding="utf-8") as f:
    SCHEMA_DOC = json.load(f)

# Server views (subscription names) -> local mirror names used by the assertions below.
TABLE_SCHEMAS: dict[str, list[str]] = SCHEMA_DOC["tables"]
VIEW_TO_MIRROR: dict[str, str] = {
    "my_player": "player",
    "my_room": "room",
    "my_room_member": "room_member",
    "my_match_bunny": "match_bunny",
    "my_kill_event": "kill_event",
    "public_room": "public_room",
}
MIRROR_PK: dict[str, str] = {
    "player": "identity",
    "room": "id",
    "room_member": "identity",
    "match_bunny": "identity",
    "kill_event": "id",
    "public_room": "id",
}
assert set(TABLE_SCHEMAS) == set(VIEW_TO_MIRROR), f"schema/view mismatch: {sorted(TABLE_SCHEMAS)}"

INPUT_LEFT = 1
INPUT_RIGHT = 2
INPUT_JUMP = 4


class ReducerError(RuntimeError):
    """Raised when SpacetimeDB rejects a CallReducer transaction."""


def normalize_value(val):
    if isinstance(val, dict) and "__identity__" in val:
        return val["__identity__"]
    if isinstance(val, list) and len(val) == 1 and isinstance(val[0], str):
        return val[0]
    return val


def decode_row(table_name: str, raw_row: str) -> dict:
    parsed = json.loads(raw_row)
    if isinstance(parsed, dict):
        return {k: normalize_value(v) for k, v in parsed.items()}
    if isinstance(parsed, list):
        cols = TABLE_SCHEMAS[table_name]
        assert len(parsed) == len(cols), f"{table_name}: expected {len(cols)} cols, got {len(parsed)}: {parsed}"
        return {col: normalize_value(val) for col, val in zip(cols, parsed)}
    raise ValueError(f"Unexpected row JSON for {table_name}: {raw_row}")


class StdbClient:
    """Async SpacetimeDB v1.json.spacetimedb client with live table mirror."""

    def __init__(self, name: str, ws_url: str):
        self.name = name
        self.ws_url = ws_url
        self.ws = None
        self.identity: str = ""
        self.tables: dict[str, dict] = {m: {} for m in MIRROR_PK}
        self._next_req_id = 1
        self._pending: dict[int, asyncio.Future] = {}
        self._initial_sub_future: asyncio.Future | None = None
        self._recv_task: asyncio.Task | None = None
        self._state_changed = asyncio.Event()
        self.tx_count = 0

    async def connect(self) -> None:
        self.ws = await websockets.connect(self.ws_url, subprotocols=["v1.json.spacetimedb"])
        assert self.ws.subprotocol == "v1.json.spacetimedb", f"Unexpected subprotocol: {self.ws.subprotocol}"
        ident_msg = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=5.0))
        assert "IdentityToken" in ident_msg, f"Expected IdentityToken, got {ident_msg}"
        self.identity = ident_msg["IdentityToken"]["identity"]["__identity__"]

        loop = asyncio.get_running_loop()
        self._initial_sub_future = loop.create_future()
        self._recv_task = asyncio.create_task(self._recv_loop())

        req_id = self._alloc_req_id()
        queries = [f"SELECT * FROM {t}" for t in TABLE_SCHEMAS]
        await self.ws.send(json.dumps({
            "Subscribe": {
                "query_strings": queries,
                "request_id": req_id,
            }
        }))
        await asyncio.wait_for(self._initial_sub_future, timeout=5.0)

    async def close(self) -> None:
        if self._recv_task and not self._recv_task.done():
            self._recv_task.cancel()
            try:
                await self._recv_task
            except asyncio.CancelledError:
                pass
        if self.ws is not None:
            await self.ws.close()
            self.ws = None

    def _alloc_req_id(self) -> int:
        rid = self._next_req_id
        self._next_req_id += 1
        return rid

    async def call(self, reducer: str, args: list | None = None, timeout: float = 5.0) -> None:
        if args is None:
            args = []
        req_id = self._alloc_req_id()
        fut = asyncio.get_running_loop().create_future()
        self._pending[req_id] = fut
        await self.ws.send(json.dumps({
            "CallReducer": {
                "reducer": reducer,
                "args": json.dumps(args),
                "request_id": req_id,
                "flags": 0,
            }
        }))
        await asyncio.wait_for(fut, timeout=timeout)

    async def call_expect_fail(self, reducer: str, args: list, expected_substr: str = "") -> str:
        try:
            await self.call(reducer, args)
        except ReducerError as exc:
            msg = str(exc)
            if expected_substr:
                assert expected_substr.lower() in msg.lower(), (
                    f"{self.name}: reducer {reducer} failed with {msg!r}, expected substring {expected_substr!r}"
                )
            return msg
        raise AssertionError(f"{self.name}: expected {reducer}({args}) to fail, but it succeeded")

    async def wait_for(self, predicate, timeout: float = 5.0, desc: str = "condition"):
        deadline = time.monotonic() + timeout
        while True:
            res = predicate(self)
            if res:
                return res
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"{self.name}: timed out waiting for {desc}")
            self._state_changed.clear()
            # Re-check after clearing event to avoid race.
            res = predicate(self)
            if res:
                return res
            await asyncio.wait_for(self._state_changed.wait(), timeout=min(remaining, 0.25))

    def _apply_tables(self, raw_tables: list[dict]) -> None:
        for table in raw_tables:
            tname = table.get("table_name")
            mirror = VIEW_TO_MIRROR.get(tname)
            if mirror is None:
                raise AssertionError(f"{self.name}: received rows for non-view table {tname!r}")
            pk = MIRROR_PK[mirror]
            store = self.tables[mirror]
            for upd in table.get("updates", []):
                for raw_del in upd.get("deletes", []):
                    row = decode_row(tname, raw_del)
                    store.pop(row[pk], None)
                for raw_ins in upd.get("inserts", []):
                    row = decode_row(tname, raw_ins)
                    store[row[pk]] = row

    async def _recv_loop(self) -> None:
        try:
            while True:
                raw = await self.ws.recv()
                msg = json.loads(raw)
                if "InitialSubscription" in msg:
                    body = msg["InitialSubscription"]
                    self._apply_tables(body["database_update"].get("tables", []))
                    if self._initial_sub_future and not self._initial_sub_future.done():
                        self._initial_sub_future.set_result(True)
                    self._state_changed.set()
                elif "TransactionUpdate" in msg:
                    self.tx_count += 1
                    tu = msg["TransactionUpdate"]
                    rc = tu.get("reducer_call", {})
                    req_id = rc.get("request_id")
                    status = tu["status"]
                    if "Committed" in status:
                        self._apply_tables(status["Committed"].get("tables", []))
                        self._state_changed.set()
                        fut = self._pending.pop(req_id, None)
                        if fut and not fut.done():
                            fut.set_result(True)
                    elif "Failed" in status:
                        fut = self._pending.pop(req_id, None)
                        if fut and not fut.done():
                            fut.set_exception(ReducerError(str(status["Failed"])))
                    elif "OutOfEnergy" in status:
                        fut = self._pending.pop(req_id, None)
                        if fut and not fut.done():
                            fut.set_exception(ReducerError("OutOfEnergy"))
                elif "TransactionUpdateLight" in msg:
                    self.tx_count += 1
                    tables = msg["TransactionUpdateLight"]["update"].get("tables", [])
                    self._apply_tables(tables)
                    self._state_changed.set()
                elif "SubscriptionError" in msg:
                    raise RuntimeError(f"SubscriptionError: {msg}")
        except asyncio.CancelledError:
            raise
        except websockets.ConnectionClosed:
            pass


def get_room_members(client: StdbClient, room_id: int) -> list[dict]:
    return sorted(
        [m for m in client.tables["room_member"].values() if m["room_id"] == room_id],
        key=lambda m: m["slot"],
    )


def get_room_bunnies(client: StdbClient, room_id: int) -> list[dict]:
    return sorted(
        [b for b in client.tables["match_bunny"].values() if b["room_id"] == room_id],
        key=lambda b: b["slot"],
    )


def get_room_kills(client: StdbClient, room_id: int) -> list[dict]:
    return sorted(
        [k for k in client.tables["kill_event"].values() if k["room_id"] == room_id],
        key=lambda k: k["id"],
    )


async def run_suite(ws_url: str) -> None:
    clients: list[StdbClient] = []

    async def spawn(name: str) -> StdbClient:
        c = StdbClient(name, ws_url)
        await c.connect()
        clients.append(c)
        return c

    try:
        # 1. Connect & Nickname validation
        print("[phase2_e2e] 1. Testing client_connected & set_nickname...")
        a = await spawn("A")
        p_a = await a.wait_for(lambda cl: cl.tables["player"].get(cl.identity), desc="Player A row")
        assert p_a["connected"] is True and p_a["room_id"] == 0
        assert 1 <= len(p_a["nickname"]) <= 16

        await a.call_expect_fail("set_nickname", ["   "], "1 and 16")
        await a.call_expect_fail("set_nickname", ["12345678901234567"], "1 and 16")
        await a.call("set_nickname", ["  DottMaster  "])
        assert a.tables["player"][a.identity]["nickname"] == "DottMaster"

        # 2. Public room creation + Private room join-by-code
        print("[phase2_e2e] 2. Testing public room browser & private join-by-code...")
        await a.call("create_room", ["Public Meadow", True])
        pub_room = await a.wait_for(
            lambda cl: next((r for r in cl.tables["room"].values() if r["name"] == "Public Meadow"), None),
            desc="Public Meadow room",
        )
        pub_id = pub_room["id"]
        assert pub_id >= 1, f"Room.id must be >= 1, got {pub_id}"
        assert len(pub_room["code"]) == 5 and pub_room["code"].isupper()
        assert pub_room["is_public"] is True
        assert pub_room["status"] == 0
        assert pub_room["win_mode"] == 0 and pub_room["win_target"] == 10
        assert pub_room["gore_enabled"] is True and pub_room["winner_slot"] == -1
        assert a.tables["player"][a.identity]["room_id"] == pub_id
        assert a.tables["room_member"][a.identity]["slot"] == 0
        assert a.tables["room_member"][a.identity]["ready"] is True

        b = await spawn("B")
        await b.call("set_nickname", ["JiffyPro"])
        # B sees Public Meadow in the public room listing (with member count, without a code).
        listing = await b.wait_for(lambda cl: cl.tables["public_room"].get(pub_id), desc="B sees public room")
        assert listing["member_count"] == 1 and "code" not in listing
        assert not b.tables["room"], "B must not see any room row before joining one"
        await b.call("join_public_room", [pub_id])
        b_mem = await b.wait_for(lambda cl: cl.tables["room_member"].get(cl.identity), desc="B room_member")
        assert b_mem["room_id"] == pub_id and b_mem["slot"] == 1 and b_mem["ready"] is False

        # Private room flow with C, D, E, F, G
        c = await spawn("C")
        await c.call("set_nickname", ["FizzAce"])
        await c.call("create_room", ["Secret Pond", False])
        priv_room = await c.wait_for(
            lambda cl: next((r for r in cl.tables["room"].values() if r["name"] == "Secret Pond"), None),
            desc="Secret Pond room",
        )
        priv_id = priv_room["id"]
        priv_code = priv_room["code"]
        assert priv_room["is_public"] is False

        # Private room code and membership must not leak to clients outside the room.
        assert priv_id not in b.tables["room"] and priv_id not in b.tables["public_room"]
        assert all(m["room_id"] == pub_id for m in b.tables["room_member"].values())
        assert set(b.tables["player"]) == {b.identity}, "Clients must only see their own player row"

        d = await spawn("D")
        await d.call("set_nickname", ["MijjiKid"])
        await d.call_expect_fail("join_public_room", [priv_id], "private")
        await d.call("join_room_by_code", [f"  {priv_code.lower()}  "])
        assert d.tables["room_member"][d.identity]["slot"] == 1

        # Nickname update propagates to RoomMember
        await c.call("set_nickname", ["FizzBoss"])
        await d.wait_for(
            lambda cl: cl.tables["room_member"].get(c.identity, {}).get("nickname") == "FizzBoss",
            desc="RoomMember nickname sync",
        )

        # 3. 4-player cap & bunny slot selection & empty room cleanup
        print("[phase2_e2e] 3. Testing 4-player cap, slot selection, & empty room cleanup...")
        e = await spawn("E")
        f = await spawn("F")
        g = await spawn("G")
        await e.call("join_room_by_code", [priv_code])
        await f.call("join_room_by_code", [priv_code])
        await c.wait_for(lambda cl: len(get_room_members(cl, priv_id)) == 4, desc="4 room members on C")
        await g.call_expect_fail("join_room_by_code", [priv_code], "full")

        # Slot taken vs free slot selection
        await d.call_expect_fail("select_bunny_slot", [0], "taken")
        await f.call("leave_room")
        await d.call("select_bunny_slot", [3])
        assert d.tables["room_member"][d.identity]["slot"] == 3

        # Empty private room deletes itself when all members leave
        await c.call("leave_room")
        await d.call("leave_room")
        await e.call("leave_room")
        await g.call_expect_fail("join_room_by_code", [priv_code], "not found")

        # 4. Host-only validation, settings validation, & host migration on disconnect
        print("[phase2_e2e] 4. Testing host-only guards & host migration on disconnect...")
        await b.call_expect_fail("update_room_settings", [0, 5, False, False, False, True], "host")
        await b.call_expect_fail("start_match", [], "host")
        await a.call_expect_fail("start_match", [], "ready")
        await a.call_expect_fail("update_room_settings", [0, 100, False, False, False, True], "between 1 and 99")
        await a.call_expect_fail("update_room_settings", [1, 5, False, False, False, True], "between 10 and 600")

        # C joins Public Meadow (slot 2), then host A disconnects -> B (slot 1) becomes host!
        await c.call("join_public_room", [pub_id])
        assert c.tables["room_member"][c.identity]["slot"] == 2
        a_identity = a.identity
        await a.close()
        await b.wait_for(
            lambda cl: cl.tables["room"].get(pub_id, {}).get("host_identity") == b.identity,
            desc="Host migration to B",
        )
        assert a_identity not in b.tables["room_member"]

        # 5. Lock-on-start, live physics, stomp KillEvent, Kill Limit victory -> return_to_lobby
        print("[phase2_e2e] 5. Testing lock-on-start, live stomp KillEvent, & Kill Limit victory...")
        if not b.tables["room_member"][b.identity]["ready"]:
            await b.call("toggle_ready")
        if not c.tables["room_member"][c.identity]["ready"]:
            await c.call("toggle_ready")

        await b.call("update_room_settings", [0, 1, False, False, False, True])
        await b.call("start_match")

        await b.wait_for(
            lambda cl: cl.tables["room"].get(pub_id, {}).get("status") == 1,
            desc="Room InProgress",
        )
        bunnies = get_room_bunnies(b, pub_id)
        assert len(bunnies) == 2
        assert all(bn["invuln_ticks"] == 15 for bn in bunnies)
        await g.wait_for(lambda cl: pub_id not in cl.tables["public_room"], desc="InProgress room leaves public listing")
        assert not g.tables["match_bunny"], "Match traffic must be scoped to room members"

        # Late join rejected while InProgress
        await g.call_expect_fail("join_public_room", [pub_id], "locked")
        await g.call_expect_fail("join_room_by_code", [pub_room["code"]], "locked")

        # Wait until spawn invulnerability wears off
        await b.wait_for(
            lambda cl: all(bn["invuln_ticks"] == 0 for bn in get_room_bunnies(cl, pub_id)),
            timeout=3.0,
            desc="invulnerability expiry",
        )

        # Drive B (slot 1, spawn [97, 194]) into the pond at x=155 and C (slot 2, spawn [33, 82])
        # off the row-8 ledge (x=144) straight down onto B's head at x=155!
        seq_b = 1
        seq_c = 1
        last_b_bits = -1
        last_c_bits = -1
        stomp_deadline = time.monotonic() + 10.0

        while b.tables["room"][pub_id]["status"] == 1 and time.monotonic() < stomp_deadline:
            bunny_b = b.tables["match_bunny"].get(b.identity)
            bunny_c = b.tables["match_bunny"].get(c.identity)
            if bunny_b is None or bunny_c is None:
                break

            # Hold B near x=155 on the pond floor
            bits_b = 0
            if bunny_b["x"] < 152.0:
                bits_b = INPUT_RIGHT
            elif bunny_b["x"] > 158.0:
                bits_b = INPUT_LEFT
            if bits_b != last_b_bits:
                await b.call("send_input", [bits_b, seq_b])
                seq_b += 1
                last_b_bits = bits_b

            # Guide C directly above B's x so C drops straight down onto B's head
            dx = bunny_b["x"] - bunny_c["x"]
            bits_c = 0
            if dx > 2.0:
                bits_c = INPUT_RIGHT
            elif dx < -2.0:
                bits_c = INPUT_LEFT

            if bits_c != last_c_bits:
                await c.call("send_input", [bits_c, seq_c])
                seq_c += 1
                last_c_bits = bits_c

            await asyncio.sleep(0.035)

        await b.wait_for(
            lambda cl: cl.tables["room"].get(pub_id, {}).get("status") == 2,
            timeout=3.0,
            desc="Kill Limit Finished transition",
        )
        fin_room = b.tables["room"][pub_id]
        assert fin_room["winner_slot"] == 2, f"Expected C (slot 2) to win, got {fin_room}"
        kills = get_room_kills(b, pub_id)
        assert len(kills) == 1
        assert kills[0]["killer_slot"] == 2 and kills[0]["victim_slot"] == 1
        assert b.tables["room_member"][c.identity]["kills"] == 1
        assert b.tables["room_member"][b.identity]["deaths"] == 1
        assert len(get_room_bunnies(b, pub_id)) == 0, "MatchBunny rows must be cleaned up on finish"

        # Verify idle schedule stopped (no ticks emitted while Finished)
        tx_before_idle = b.tx_count
        await asyncio.sleep(0.25)
        assert b.tx_count == tx_before_idle, "Schedule did not stop when no rooms InProgress!"

        # 6. return_to_lobby
        print("[phase2_e2e] 6. Testing return_to_lobby...")
        await c.call_expect_fail("return_to_lobby", [], "host")
        await b.call("return_to_lobby")
        await b.wait_for(
            lambda cl: cl.tables["room"].get(pub_id, {}).get("status") == 0,
            desc="Room back to Waiting",
        )
        reset_room = b.tables["room"][pub_id]
        assert reset_room["tick_count"] == 0 and reset_room["elapsed_ms"] == 0
        assert reset_room["winner_slot"] == -1
        assert len(get_room_kills(b, pub_id)) == 0
        assert b.tables["room_member"][b.identity]["ready"] is True
        assert b.tables["room_member"][c.identity]["ready"] is False
        assert b.tables["room_member"][c.identity]["kills"] == 0
        assert b.tables["room_member"][b.identity]["deaths"] == 0

        # 7. Disconnect drop-to-1 ends InProgress match
        print("[phase2_e2e] 7. Testing disconnect drop-to-1 ends InProgress match...")
        await d.call("create_room", ["Drop Test", False])
        drop_room = await d.wait_for(
            lambda cl: next((r for r in cl.tables["room"].values() if r["name"] == "Drop Test"), None),
            desc="Drop Test room",
        )
        drop_id = drop_room["id"]
        await e.call("join_room_by_code", [drop_room["code"]])
        await e.call("toggle_ready")
        await d.call("start_match")
        await d.wait_for(lambda cl: cl.tables["room"][drop_id]["status"] == 1, desc="Drop Test InProgress")
        await e.close()
        await d.wait_for(lambda cl: cl.tables["room"][drop_id]["status"] == 2, desc="Drop Test Finished on disconnect")
        assert d.tables["room"][drop_id]["winner_slot"] == 0
        assert len(get_room_bunnies(d, drop_id)) == 0
        await d.call("leave_room")

        # 8. Time Limit victory (10s) & schedule cleanup
        print("[phase2_e2e] 8. Testing Time Limit (10s) victory & idle schedule shutdown...")
        await c.call("toggle_ready")
        await b.call("update_room_settings", [1, 10, True, False, False, False])
        await b.call("start_match")
        await b.wait_for(lambda cl: cl.tables["room"][pub_id]["status"] == 1, desc="Timed match InProgress")
        await b.wait_for(
            lambda cl: cl.tables["room"].get(pub_id, {}).get("status") == 2,
            timeout=13.0,
            desc="Timed match Finished after 10s",
        )
        timed_room = b.tables["room"][pub_id]
        assert timed_room["elapsed_ms"] >= 10000, f"Expected elapsed_ms >= 10000, got {timed_room['elapsed_ms']}"
        assert timed_room["tick_count"] >= 300, f"Expected tick_count >= 300, got {timed_room['tick_count']}"
        assert timed_room["winner_slot"] == -1, f"0-0 tie should yield winner_slot=-1, got {timed_room['winner_slot']}"
        assert len(get_room_bunnies(b, pub_id)) == 0

        tx_after_timed = b.tx_count
        await asyncio.sleep(0.25)
        assert b.tx_count == tx_after_timed, "Schedule did not stop after timed match finished!"

        print("[phase2_e2e] PASS: All 8 Phase 2 multiplayer E2E scenarios passed!")
    finally:
        for cl in clients:
            await cl.close()


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    asyncio.run(run_suite(url))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
