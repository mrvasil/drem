#!/usr/bin/env python3

import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


INSTALL_HOME = Path(os.environ.get("DREM_INSTALL_HOME", Path.home()))
HOOK_BINARY = Path(
    os.environ.get(
        "DREM_HOOK_BINARY",
        INSTALL_HOME / "Applications/drem.app/Contents/MacOS/drem-hook",
    )
)
MARKERS = (
    "/drem.app/Contents/MacOS/drem-hook",
    "/Agent Watch.app/Contents/MacOS/agentwatch-hook",
)


def is_our_handler(item: object) -> bool:
    return isinstance(item, dict) and any(
        marker in str(item.get("command", "")) for marker in MARKERS
    )


def load(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def backup(path: Path) -> Path | None:
    if not path.exists():
        return None
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    destination = path.with_name(f"{path.name}.drem-backup-{timestamp}")
    shutil.copy2(path, destination)
    return destination


def handler(provider: str) -> dict:
    return {
        "type": "command",
        "command": f'"{HOOK_BINARY}" {provider}',
        "timeout": 3,
    }


def add_event(hooks: dict, event: str, provider: str) -> None:
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        raise ValueError(f"hooks.{event} must be an array")

    for group in groups:
        if not isinstance(group, dict):
            continue
        entries = group.get("hooks")
        if not isinstance(entries, list):
            continue
        group["hooks"] = [
            item
            for item in entries
            if not is_our_handler(item)
        ]

    groups[:] = [
        group
        for group in groups
        if not isinstance(group, dict) or group.get("hooks")
    ]
    groups.append({"hooks": [handler(provider)]})


def remove_drem_handlers(hooks: dict) -> None:
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            entries = group.get("hooks")
            if not isinstance(entries, list):
                continue
            group["hooks"] = [
                item
                for item in entries
                if not is_our_handler(item)
            ]
        groups[:] = [
            group
            for group in groups
            if not isinstance(group, dict) or group.get("hooks")
        ]
        if not groups:
            hooks.pop(event, None)


def atomic_write(path: Path, data: dict, original_mode: int | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(temporary_name, original_mode if original_mode is not None else 0o600)
        os.replace(temporary_name, path)
    except Exception:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def install(path: Path, provider: str, events: list[str]) -> None:
    data = load(path)
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"{path}: hooks must be an object")
    remove_drem_handlers(hooks)
    for event in events:
        add_event(hooks, event, provider)

    original_mode = path.stat().st_mode & 0o777 if path.exists() else None
    saved = backup(path)
    atomic_write(path, data, original_mode)
    print(f"updated: {path}")
    if saved:
        print(f"backup:  {saved}")


def main() -> int:
    if not HOOK_BINARY.is_file():
        print(f"hook binary not found: {HOOK_BINARY}", file=sys.stderr)
        return 1

    install(
        INSTALL_HOME / ".codex/hooks.json",
        "codex",
        ["SessionStart", "UserPromptSubmit", "Stop", "Interrupt", "SessionEnd"],
    )
    install(
        INSTALL_HOME / ".claude/settings.json",
        "claude",
        ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
