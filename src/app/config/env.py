from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path


def _parse_key_value_config(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def _parse_sqlserver_candidates(project_config: Path) -> list[tuple[str, bool]]:
    candidates: list[tuple[str, bool]] = []
    if not project_config.exists():
        return candidates

    pattern = re.compile(r"^sqlserver\s*:\s*([^,]+)\s*,\s*(true|false)\s*$", re.IGNORECASE)
    for raw in project_config.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = pattern.match(line)
        if not match:
            continue
        server = match.group(1).strip().strip('"').strip("'")
        requires_vpn = match.group(2).lower() == "true"
        candidates.append((server, requires_vpn))

    candidates.sort(key=lambda item: (item[1], item[0]))
    return candidates


def _load_credentials_from_windows_store(project_folder: str) -> tuple[str | None, str | None]:
    cred_path = Path.home() / f".{project_folder}" / "credentials.xml"
    if not cred_path.exists() and project_folder != "api_so":
        fallback = Path.home() / ".api_so" / "credentials.xml"
        cred_path = fallback if fallback.exists() else cred_path

    if not cred_path.exists():
        return None, None

    ps_script = (
        f"$p=Join-Path $env:USERPROFILE '.{project_folder}\\credentials.xml';"
        "if(-not (Test-Path $p)){"
        "$p=Join-Path $env:USERPROFILE '.api_so\\credentials.xml'};"
        "if(Test-Path $p){"
        "$c=Import-Clixml $p;"
        "Write-Output $c.UserName;"
        "Write-Output $c.GetNetworkCredential().Password}"
    )

    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_script],
            capture_output=True,
            text=True,
            check=False,
        )
    except Exception:
        return None, None

    if result.returncode != 0:
        return None, None

    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(lines) < 2:
        return None, None
    return lines[0], lines[1]


def bootstrap_db_environment(base_dir: Path) -> None:
    project_folder = base_dir.name
    local_cfg = _parse_key_value_config(Path.home() / f".{project_folder}" / "config.txt")
    if not local_cfg:
        local_cfg = _parse_key_value_config(Path.home() / ".api_so" / "config.txt")

    if not os.getenv("DB_SERVER"):
        candidates = _parse_sqlserver_candidates(base_dir / "config.txt")
        if candidates:
            os.environ["DB_SERVER"] = candidates[0][0]
            os.environ["DB_REQUIRES_VPN"] = "true" if candidates[0][1] else "false"
        elif local_cfg.get("DB_SERVER"):
            os.environ["DB_SERVER"] = local_cfg["DB_SERVER"]

    if not os.getenv("DB_DATABASE"):
        os.environ["DB_DATABASE"] = local_cfg.get("DB_DATABASE", "GJO_CCO")

    if not os.getenv("DB_DRIVER") and local_cfg.get("DB_DRIVER"):
        os.environ["DB_DRIVER"] = local_cfg["DB_DRIVER"]

    if not os.getenv("DB_USER") or not os.getenv("DB_PASSWORD"):
        user, password = _load_credentials_from_windows_store(project_folder)
        if user and not os.getenv("DB_USER"):
            os.environ["DB_USER"] = user
        if password and not os.getenv("DB_PASSWORD"):
            os.environ["DB_PASSWORD"] = password
