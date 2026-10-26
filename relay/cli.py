"""Relay command line entry point."""
from __future__ import annotations

import argparse
import json
import sys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="relay", description="Local coding-session dashboard")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve", help="run the loopback dashboard API")
    serve.add_argument("--port", type=int, default=9778)
    listing = sub.add_parser("sessions", help="print session metadata")
    listing.add_argument("--json", action="store_true", dest="as_json")
    listing.add_argument("--demo", action="store_true", help="show labelled synthetic sessions")
    args = parser.parse_args(argv)
    if args.command == "serve":
        if not 1 <= args.port <= 65535:
            parser.error("--port must be between 1 and 65535")
        import uvicorn
        uvicorn.run("relay.server:app", host="127.0.0.1", port=args.port, access_log=False)
        return 0
    from .adapters import collect_sessions
    from .store import Store
    from pathlib import Path
    import os
    state = Path(os.environ.get("RELAY_STATE_DIR", "~/.local/share/relay")).expanduser()
    snapshot = Store(state).apply(collect_sessions(limit=100).to_dict())
    if args.demo:
        from .server import demo_snapshot
        snapshot = Store(state).apply(demo_snapshot())
    if args.as_json:
        print(json.dumps(snapshot, ensure_ascii=False, indent=2))
    else:
        for session in snapshot["sessions"]:
            print(f"{session['provider']:<7} {session['status']:<11} {session['display_name']} [{session['id']}]")
        print(f"{snapshot['total']} session(s)" + (" (synthetic demo)" if args.demo else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
