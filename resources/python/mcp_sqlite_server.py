#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FerIDE yerleşik SQLite MCP sunucusu (stdio, yalnızca Python standart kütüphanesi)
================================================================================
Resmî "mcp-server-sqlite" arşivlendi ve güncel MCP/pydantic sürümleriyle çalışmıyor.
Bu sunucu aynı araç adlarını sunar, hiçbir bağımlılık gerektirmez ve Linux, Windows
ve macOS'ta anında açılır.

Kullanım:  python3 mcp_sqlite_server.py --db-path ~/.feride/feride_knowledge.db
"""

import argparse
import json
import os
import sqlite3
import sys

PROTOCOL_VERSION = "2025-06-18"
MAX_ROWS = 200

TOOLS = [
    {
        "name": "read_query",
        "description": "Veritabanında SELECT (veya WITH/PRAGMA/EXPLAIN) sorgusu çalıştırır ve satırları JSON olarak döndürür.",
        "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "SELECT sorgusu"}}, "required": ["query"]},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "write_query",
        "description": "INSERT, UPDATE veya DELETE sorgusu çalıştırır; etkilenen satır sayısını döndürür.",
        "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "INSERT/UPDATE/DELETE sorgusu"}}, "required": ["query"]},
    },
    {
        "name": "create_table",
        "description": "CREATE TABLE sorgusuyla yeni bir tablo oluşturur.",
        "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "CREATE TABLE sorgusu"}}, "required": ["query"]},
    },
    {
        "name": "list_tables",
        "description": "Veritabanındaki tabloları listeler.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "describe_table",
        "description": "Bir tablonun sütunlarını ve tiplerini gösterir.",
        "inputSchema": {"type": "object", "properties": {"table_name": {"type": "string"}}, "required": ["table_name"]},
        "annotations": {"readOnlyHint": True},
    },
]


class Db:
    def __init__(self, path: str):
        path = os.path.expanduser(path)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.conn = sqlite3.connect(path)
        self.conn.row_factory = sqlite3.Row

    def rows(self, sql: str, params=()):
        cur = self.conn.execute(sql, params)
        out = [dict(r) for r in cur.fetchmany(MAX_ROWS + 1)]
        more = len(out) > MAX_ROWS
        return out[:MAX_ROWS], more

    def call(self, name: str, args: dict) -> str:
        q = (args.get("query") or "").strip()
        first = q.split(None, 1)[0].upper() if q else ""
        if name == "read_query":
            if first not in ("SELECT", "WITH", "PRAGMA", "EXPLAIN"):
                raise ValueError("read_query yalnızca SELECT/WITH/PRAGMA/EXPLAIN sorguları içindir.")
            rows, more = self.rows(q)
            return json.dumps(rows, ensure_ascii=False, default=str) + (f"\n(ilk {MAX_ROWS} satır gösterildi)" if more else "")
        if name == "write_query":
            if first not in ("INSERT", "UPDATE", "DELETE", "REPLACE"):
                raise ValueError("write_query yalnızca INSERT/UPDATE/DELETE/REPLACE içindir.")
            cur = self.conn.execute(q)
            self.conn.commit()
            return f"{cur.rowcount} satır etkilendi."
        if name == "create_table":
            if not q.upper().startswith("CREATE TABLE"):
                raise ValueError("create_table yalnızca CREATE TABLE sorguları içindir.")
            self.conn.execute(q)
            self.conn.commit()
            return "Tablo oluşturuldu."
        if name == "list_tables":
            rows, _ = self.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            return json.dumps([r["name"] for r in rows], ensure_ascii=False)
        if name == "describe_table":
            table = str(args.get("table_name", ""))
            rows, _ = self.rows("SELECT name, type, \"notnull\", pk FROM pragma_table_info(?)", (table,))
            if not rows:
                raise ValueError(f"Tablo bulunamadı: {table}")
            return json.dumps(rows, ensure_ascii=False)
        raise ValueError(f"Bilinmeyen araç: {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db-path", default=os.path.join(os.path.expanduser("~"), ".feride", "feride_knowledge.db"))
    db = Db(ap.parse_args().db_path)

    def send(msg):
        sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        mid, method = msg.get("id"), msg.get("method", "")
        if mid is None:
            continue  # bildirim (notifications/initialized vb.)
        try:
            if method == "initialize":
                version = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL_VERSION
                result = {
                    "protocolVersion": version,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "feride-sqlite", "version": "1.0.0"},
                }
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = msg.get("params") or {}
                try:
                    text = db.call(params.get("name", ""), params.get("arguments") or {})
                    result = {"content": [{"type": "text", "text": text}], "isError": False}
                except Exception as e:  # noqa: BLE001 — araç hatası modele açıklanır
                    result = {"content": [{"type": "text", "text": f"Hata: {e}"}], "isError": True}
            else:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Bilinmeyen yöntem: {method}"}})
                continue
            send({"jsonrpc": "2.0", "id": mid, "result": result})
        except Exception as e:  # noqa: BLE001
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}})


if __name__ == "__main__":
    main()
