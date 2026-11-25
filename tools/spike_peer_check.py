#!/usr/bin/env python3
"""Phase 0 Python websockets verification probe for SpacetimeDB v2.16.3.

Connects using `v1.json.spacetimedb`, verifies `IdentityToken`, `InitialSubscription`,
`send_ping`, ~30 Hz `set_ticking(true)` ticks via `TransactionUpdateLight`, and clean
stop via `set_ticking(false)`.
"""

import asyncio
import json
import sys
import time
import websockets

DEFAULT_URL = "ws://127.0.0.1:3100/v1/database/jumpernbumper/subscribe"


def decode_row(raw_row: str, columns: list[str]) -> dict:
    parsed = json.loads(raw_row)
    if isinstance(parsed, dict):
        return parsed
    if isinstance(parsed, list) and len(parsed) == len(columns):
        return dict(zip(columns, parsed))
    raise ValueError(f"Unexpected row format: {raw_row}")


def extract_spike_rows(tables: list[dict]) -> list[dict]:
    rows: list[dict] = []
    cols = ["id", "counter", "last_message"]
    for table in tables:
        if table.get("table_name") != "spike_state":
            continue
        for upd in table.get("updates", []):
            for raw_ins in upd.get("inserts", []):
                rows.append(decode_row(raw_ins, cols))
    return rows


async def run_probe(ws_url: str) -> None:
    async with websockets.connect(ws_url, subprotocols=["v1.json.spacetimedb"]) as ws:
        assert ws.subprotocol == "v1.json.spacetimedb", f"Unexpected subprotocol: {ws.subprotocol}"

        # 1. IdentityToken
        ident_msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=5.0))
        assert "IdentityToken" in ident_msg, f"Expected IdentityToken, got {ident_msg}"
        identity_hex = ident_msg["IdentityToken"]["identity"]["__identity__"]
        print(f"[py_probe] IdentityToken: {identity_hex}")

        # 2. Subscribe -> InitialSubscription
        await ws.send(json.dumps({
            "Subscribe": {
                "query_strings": ["SELECT * FROM spike_state"],
                "request_id": 1,
            }
        }))
        init_msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=5.0))
        assert "InitialSubscription" in init_msg, f"Expected InitialSubscription, got {init_msg}"
        init_rows = extract_spike_rows(
            init_msg["InitialSubscription"]["database_update"]["tables"]
        )
        assert len(init_rows) == 1, f"Expected 1 spike_state row, got {init_rows}"
        counter = int(init_rows[0]["counter"])
        last_msg = init_rows[0]["last_message"]
        print(f"[py_probe] InitialSubscription: counter={counter}, last_message={last_msg!r}")

        # 3. Call send_ping + set_ticking(true)
        await ws.send(json.dumps({
            "CallReducer": {
                "reducer": "send_ping",
                "args": json.dumps(["hello_from_python"]),
                "request_id": 2,
                "flags": 0,
            }
        }))
        await ws.send(json.dumps({
            "CallReducer": {
                "reducer": "set_ticking",
                "args": json.dumps([True]),
                "request_id": 3,
                "flags": 0,
            }
        }))

        tick_start = time.monotonic()
        increments = 0
        deadline = tick_start + 3.0
        while time.monotonic() < deadline:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=2.0))
            tables = []
            if "TransactionUpdate" in msg:
                status = msg["TransactionUpdate"]["status"]
                assert "Committed" in status, f"Reducer failed: {status}"
                tables = status["Committed"].get("tables", [])
            elif "TransactionUpdateLight" in msg:
                tables = msg["TransactionUpdateLight"]["update"].get("tables", [])

            for row in extract_spike_rows(tables):
                next_counter = int(row["counter"])
                if next_counter > counter:
                    increments += 1
                counter = next_counter
                last_msg = row["last_message"]

            if last_msg == "hello_from_python" and increments >= 10:
                break

        elapsed = time.monotonic() - tick_start
        assert last_msg == "hello_from_python", f"Expected last_message='hello_from_python', got {last_msg!r}"
        assert increments >= 10, f"Expected >=10 counter increments, got {increments}"
        hz = increments / max(elapsed, 0.001)
        print(f"[py_probe] Observed {increments} updates in {elapsed*1000:.0f} ms (~{hz:.1f} Hz), counter={counter}")

        # 4. Stop ticking and wait for set_ticking(false) commit
        await ws.send(json.dumps({
            "CallReducer": {
                "reducer": "set_ticking",
                "args": json.dumps([False]),
                "request_id": 4,
                "flags": 0,
            }
        }))
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=2.0))
            if "TransactionUpdate" in msg:
                tu = msg["TransactionUpdate"]
                rc = tu.get("reducer_call", {})
                if rc.get("request_id") == 4:
                    assert "Committed" in tu["status"], f"set_ticking(false) failed: {tu['status']}"
                    break
                for row in extract_spike_rows(tu["status"].get("Committed", {}).get("tables", [])):
                    counter = int(row["counter"])
            elif "TransactionUpdateLight" in msg:
                for row in extract_spike_rows(msg["TransactionUpdateLight"]["update"].get("tables", [])):
                    counter = int(row["counter"])

        # 5. Verify zero updates arrive after set_ticking(false) committed
        quiet_until = time.monotonic() + 0.25
        while time.monotonic() < quiet_until:
            remaining = max(0.01, quiet_until - time.monotonic())
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=remaining))
                raise AssertionError(f"Unexpected post-stop message: {msg}")
            except asyncio.TimeoutError:
                break

        print(f"[py_probe] Verified ticking stopped cleanly at counter={counter}")


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    asyncio.run(run_probe(url))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
