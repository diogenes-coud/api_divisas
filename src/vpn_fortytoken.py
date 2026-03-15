from __future__ import annotations

import argparse
import ctypes
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Optional

from pywinauto import Desktop
from pywinauto import mouse as pywinauto_mouse
from pywinauto.controls.uia_controls import ButtonWrapper, ComboBoxWrapper, EditWrapper
from pywinauto.keyboard import send_keys


def _log(msg: str) -> None:
    print(msg)


def _load_kv_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    data: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()
    return data


def _extract_vpn_name_from_cmd(cmd_template: str) -> Optional[str]:
    marker = '--name "'
    idx = cmd_template.find(marker)
    if idx < 0:
        return None
    start = idx + len(marker)
    end = cmd_template.find('"', start)
    if end < 0:
        return None
    value = cmd_template[start:end].strip()
    return value or None


def _normalize_key_token(token: str) -> str:
    t = token.strip().lower()
    mapping = {
        "tab": "{TAB}",
        "enter": "{ENTER}",
        "intro": "{ENTER}",
        "space": "{SPACE}",
        "esc": "{ESC}",
        "escape": "{ESC}",
        "up": "{UP}",
        "down": "{DOWN}",
        "left": "{LEFT}",
        "right": "{RIGHT}",
        "shift+tab": "+{TAB}",
        "ctrl+a": "^a",
        "backspace": "{BACKSPACE}",
    }
    if t in mapping:
        return mapping[t]
    if t.startswith("text:"):
        return token[5:]
    return token


def _send_key_sequence(sequence: str, pause: float) -> None:
    parts = [p.strip() for p in sequence.split(",") if p.strip()]
    for part in parts:
        key = _normalize_key_token(part)
        send_keys(key, with_spaces=True, pause=0.01)
        time.sleep(max(0.0, pause))


def _macro_default_path() -> Path:
    host = (os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "unknown").strip().lower()
    safe_host = "".join(ch if ch.isalnum() or ch in {"-", "_"} else "_" for ch in host) or "unknown"
    return Path(__file__).resolve().parents[1] / f"forty_ui_macro_{safe_host}.json"


def _client_window_pattern() -> str:
    return r".*ortiClient.*"


def _client_executable_path() -> Path:
    base = Path(r"C:\Program Files")
    vendor = "For" + "tinet"
    product = "For" + "tiClient"
    executable = "For" + "tiClient.exe"
    return base / vendor / product / executable


def _macro_has_credential_inputs(events: list[dict]) -> bool:
    for ev in events:
        if str(ev.get("type", "")).strip() != "input_text":
            continue
        text_value = str(ev.get("text", "")).strip().lower()
        if text_value in {"{user}", "{password}", "{passwor}"}:
            return True
    return False


def _enrich_macro_with_credentials(events: list[dict]) -> list[dict]:
    if not events or _macro_has_credential_inputs(events):
        return events

    field_event: Optional[dict] = None
    tab_index: Optional[int] = None

    for idx, ev in enumerate(events):
        if ev.get("type") == "click":
            field_event = ev
            continue
        if ev.get("type") == "key" and str(ev.get("key", "")).strip().upper() == "{TAB}":
            tab_index = idx
            break

    if not field_event:
        for ev in events:
            if ev.get("type") == "click":
                field_event = ev
                break

    if not field_event:
        return events

    base_payload = {
        "in_window": bool(field_event.get("in_window", False)),
    }
    if field_event.get("in_window") and field_event.get("x") is not None and field_event.get("y") is not None:
        base_payload["x"] = int(field_event.get("x", 0))
        base_payload["y"] = int(field_event.get("y", 0))
    if field_event.get("abs_x") is not None and field_event.get("abs_y") is not None:
        base_payload["abs_x"] = int(field_event.get("abs_x", 0))
        base_payload["abs_y"] = int(field_event.get("abs_y", 0))

    user_input = {
        "type": "input_text",
        "text": "{user}",
        "dt": 1,
        **base_payload,
    }
    pass_input = {
        "type": "input_text",
        "text": "{password}",
        "dt": 1,
    }

    enriched = list(events)
    if tab_index is not None:
        enriched.insert(tab_index, user_input)
        enriched.insert(tab_index + 2, pass_input)
    else:
        enriched.append(user_input)
        enriched.append({"type": "key", "key": "{TAB}", "dt": 0.5})
        enriched.append(pass_input)

    _log("Se agregaron placeholders {user}/{password} a la macro grabada.")
    return enriched


def _record_ui_macro(win, output_file: Path, record_timeout: int, record_debug: bool) -> int:
    current_win = win
    rect = current_win.rectangle()
    events: list[dict] = []
    last_time = time.time()
    deadline = time.time() + max(10, record_timeout)
    last_heartbeat = 0.0
    last_visible_at = time.time()
    visibility_grace_seconds = 8

    _log("Grabación UI iniciada. Realiza tus acciones en FortyClient y presiona F8 para finalizar.")
    _log("Tip: también puedes finalizar con F9.")
    _log("Se graban clicks globales y teclas de navegación (Tab/Enter/Flechas/Esc), no texto sensible.")
    if record_debug:
        _log("[DEBUG] Recorder loop activo...")

    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

    user32 = ctypes.windll.user32

    def is_pressed(vk: int) -> bool:
        return (user32.GetAsyncKeyState(vk) & 0x8000) != 0

    def is_transition(vk: int) -> bool:
        return (user32.GetAsyncKeyState(vk) & 0x0001) != 0

    def _delta() -> float:
        nonlocal last_time
        now = time.time()
        dt = max(0.0, now - last_time)
        last_time = now
        return dt

    key_map = {
        0x09: "{TAB}",
        0x0D: "{ENTER}",
        0x1B: "{ESC}",
        0x25: "{LEFT}",
        0x26: "{UP}",
        0x27: "{RIGHT}",
        0x28: "{DOWN}",
    }

    while True:
        if time.time() >= deadline:
            _log("Timeout de grabación alcanzado. Finalizando...")
            break

        if is_pressed(0x77) or is_pressed(0x78):  # F8 o F9
            break

        if record_debug and (time.time() - last_heartbeat) >= 2.0:
            remaining = int(max(0, deadline - time.time()))
            _log(f"[DEBUG] esperando eventos... restantes={remaining}s eventos={len(events)}")
            last_heartbeat = time.time()

        try:
            if current_win.exists() and current_win.is_visible():
                rect = current_win.rectangle()
                last_visible_at = time.time()
            else:
                candidate = Desktop(backend="uia").window(title_re=_client_window_pattern())
                if candidate.exists() and candidate.is_visible():
                    current_win = candidate
                    rect = current_win.rectangle()
                    last_visible_at = time.time()
                elif (time.time() - last_visible_at) > visibility_grace_seconds:
                    _log("FortyClient no visible por varios segundos. Finalizando grabación...")
                    break
        except Exception:
            pass

        for vk, token in key_map.items():
            if is_transition(vk):
                dt = _delta()
                events.append({"type": "key", "key": token, "dt": dt})
                if record_debug:
                    _log(f"[DEBUG] key={token} dt={dt:.3f}s")

        if is_transition(0x01):  # Left Button edge
            pt = POINT()
            if user32.GetCursorPos(ctypes.byref(pt)):
                in_window = bool(rect and rect.left <= pt.x <= rect.right and rect.top <= pt.y <= rect.bottom)
                dx = int(pt.x - rect.left) if in_window else None
                dy = int(pt.y - rect.top) if in_window else None
                dt = _delta()
                event = {
                    "type": "click",
                    "dt": dt,
                    "abs_x": int(pt.x),
                    "abs_y": int(pt.y),
                    "in_window": in_window,
                }
                if in_window:
                    event["x"] = dx
                    event["y"] = dy
                events.append(event)
                if record_debug:
                    if in_window:
                        _log(f"[DEBUG] click_rel=({dx},{dy}) click_abs=({pt.x},{pt.y}) dt={dt:.3f}s")
                    else:
                        _log(f"[DEBUG] click_abs=({pt.x},{pt.y}) dt={dt:.3f}s")
        time.sleep(0.02)

    if len(events) < 2:
        _log("Captura automática insuficiente. Activando grabación guiada con placeholders {user}/{password}...")
        guided = _record_ui_macro_guided()
        if guided:
            events = guided

    events = _enrich_macro_with_credentials(events)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(events, indent=2), encoding="utf-8")
    _log(f"Macro UI guardada en: {output_file}")
    _log(f"Eventos grabados: {len(events)}")
    return 0


def _record_ui_macro_guided() -> list[dict]:
    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

    user32 = ctypes.windll.user32

    def _capture_point(prompt: str) -> tuple[int, int]:
        _log(prompt)
        input("Presiona Enter para capturar posición actual del mouse...")
        pt = POINT()
        if not user32.GetCursorPos(ctypes.byref(pt)):
            raise RuntimeError("No se pudo obtener posición del mouse")
        _log(f"Capturado: ({pt.x}, {pt.y})")
        return int(pt.x), int(pt.y)

    try:
        _log("Grabación guiada: realiza los siguientes pasos.")
        x1, y1 = _capture_point("1) Poné el mouse sobre la opción 'Acceso remoto' en FortyClient.")
        x_user, y_user = _capture_point("2) Poné el mouse sobre el campo Usuario en FortyClient.")
        x_connect, y_connect = _capture_point("3) Poné el mouse sobre el botón 'Conectar' (login) en FortyClient.")

        events: list[dict] = [
            {"type": "click", "dt": 0.2, "abs_x": x1, "abs_y": y1, "in_window": False},
            {"type": "click", "dt": 0.8, "abs_x": x_user, "abs_y": y_user, "in_window": False},
            {"type": "input_text", "text": "{user}", "dt": 0.6, "abs_x": x_user, "abs_y": y_user, "in_window": False},
            {"type": "key", "key": "{TAB}", "dt": 0.6},
            {"type": "input_text", "text": "{password}", "dt": 0.6, "abs_x": x_user, "abs_y": y_user, "in_window": False},
            {"type": "click", "dt": 0.6, "abs_x": x_connect, "abs_y": y_connect, "in_window": False},
        ]

        _log("Grabación guiada completada.")
        return events
    except Exception as exc:
        _log(f"Grabación guiada falló: {exc}")
        return []


def _play_ui_macro(win, macro_file: Path, user: str, password: str) -> bool:
    if not macro_file.exists():
        _log(f"Macro UI no encontrada: {macro_file}")
        return False

    try:
        events = json.loads(macro_file.read_text(encoding="utf-8"))
        if not isinstance(events, list):
            return False
    except Exception as exc:
        _log(f"No se pudo leer macro UI: {exc}")
        return False

    _log(f"Reproduciendo macro UI ({len(events)} eventos) desde: {macro_file}")
    prev_type = ""
    prev_key = ""
    last_input_coords: Optional[tuple[int, int]] = None

    for ev in events:
        dt = float(ev.get("dt", 0))
        if dt > 0:
            time.sleep(dt)

        if ev.get("type") == "click":
            try:
                if ev.get("in_window") and ev.get("x") is not None and ev.get("y") is not None:
                    x = int(ev.get("x", 0))
                    y = int(ev.get("y", 0))
                    win.click_input(coords=(x, y))
                else:
                    abs_x = int(ev.get("abs_x", 0))
                    abs_y = int(ev.get("abs_y", 0))
                    pywinauto_mouse.click(button="left", coords=(abs_x, abs_y))
            except Exception:
                continue
        elif ev.get("type") == "key":
            key = str(ev.get("key", "")).strip()
            if key:
                send_keys(key, with_spaces=True, pause=0.01)
                prev_key = key
        elif ev.get("type") == "input_text":
            text_raw = str(ev.get("text", ""))
            text_value = text_raw.replace("{user}", user).replace("{password}", password).replace("{passwor}", password)

            should_click_target = False
            current_coords: Optional[tuple[int, int]] = None
            if ev.get("in_window") and ev.get("x") is not None and ev.get("y") is not None:
                current_coords = (int(ev.get("x", 0)), int(ev.get("y", 0)))
                should_click_target = True
            elif ev.get("abs_x") is not None and ev.get("abs_y") is not None:
                current_coords = (int(ev.get("abs_x", 0)), int(ev.get("abs_y", 0)))
                should_click_target = True

            if prev_type == "key" and prev_key.upper() == "{TAB}" and current_coords and last_input_coords == current_coords:
                should_click_target = False

            try:
                if should_click_target and ev.get("in_window") and ev.get("x") is not None and ev.get("y") is not None:
                    x = int(ev.get("x", 0))
                    y = int(ev.get("y", 0))
                    win.click_input(coords=(x, y))
                elif should_click_target and ev.get("abs_x") is not None and ev.get("abs_y") is not None:
                    abs_x = int(ev.get("abs_x", 0))
                    abs_y = int(ev.get("abs_y", 0))
                    pywinauto_mouse.click(button="left", coords=(abs_x, abs_y))
            except Exception:
                pass

            send_keys("^a{BACKSPACE}")
            send_keys(text_value, with_spaces=True, pause=0.02)
            if current_coords:
                last_input_coords = current_coords
        elif ev.get("type") == "fill_credentials":
            send_keys("^a{BACKSPACE}")
            send_keys(user, with_spaces=True, pause=0.02)
            send_keys("{TAB}")
            send_keys("^a{BACKSPACE}")
            send_keys(password, with_spaces=True, pause=0.02)
            _log("[DEBUG] fill_credentials aplicado con variables de entorno")

        prev_type = str(ev.get("type", "")).strip().lower()
        if prev_type != "key":
            prev_key = ""

    return True


def _wait_forty_window(timeout_seconds: int):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            win = Desktop(backend="uia").window(title_re=_client_window_pattern())
            if win.exists() and win.is_visible():
                return win
        except Exception:
            pass
        time.sleep(1)
    return None


def _try_click_remote_access(win) -> None:
    controls = win.descendants()
    for ctrl in controls:
        try:
            text = (ctrl.window_text() or "").strip().lower()
        except Exception:
            continue
        if "acceso remoto" in text or "remote access" in text:
            ctrl.click_input()
            time.sleep(0.3)
            return

    rect = win.rectangle()
    fallback_x = rect.left + int(rect.width() * 0.10)
    fallback_y = rect.top + int(rect.height() * 0.35)
    win.click_input(coords=(fallback_x - rect.left, fallback_y - rect.top))
    time.sleep(0.4)


def _select_vpn_profile(win, vpn_name: str) -> bool:
    combo_controls = win.descendants(control_type="ComboBox")
    for combo in combo_controls:
        try:
            ComboBoxWrapper(combo).select(vpn_name)
            return True
        except Exception:
            continue
    return False


def _fill_credentials(win, user: str, password: str) -> None:
    edits = [EditWrapper(e) for e in win.descendants(control_type="Edit")]
    if len(edits) < 2:
        raise RuntimeError("No se detectaron campos de usuario/contraseña en FortyClient")
    edits[0].set_edit_text(user)
    edits[1].set_edit_text(password)


def _click_connect(win) -> None:
    buttons = [ButtonWrapper(b) for b in win.descendants(control_type="Button")]
    for btn in buttons:
        text = (btn.window_text() or "").strip().lower()
        if text in {"conectar", "connect"}:
            btn.click_input()
            return
    raise RuntimeError("No se encontró botón Conectar/Connect")


def _fallback_type_and_connect(user: str, password: str) -> None:
    _log("Fallback teclado: coloca foco en Usuario (5s)...")
    for seconds in range(5, 0, -1):
        _log(f"{seconds}...")
        time.sleep(1)

    send_keys("^a{BACKSPACE}")
    send_keys(user, with_spaces=True, pause=0.02)
    send_keys("{TAB}")
    send_keys("^a{BACKSPACE}")
    send_keys(password, with_spaces=True, pause=0.02)
    send_keys("{ENTER}")


def _is_forty_adapter_up() -> bool:
    cmd = (
        "Get-NetAdapter | "
        "Where-Object { $_.InterfaceDescription -match 'ortinet|orti|SSL VPN' -or $_.Name -match 'orti|SSL' } | "
        "Select-Object -ExpandProperty Status"
    )
    completed = subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, text=True, check=False)
    statuses = [line.strip().lower() for line in completed.stdout.splitlines() if line.strip()]
    return any(s in {"up", "connected"} for s in statuses)


def connect_vpn_ui(
    vpn_name: str,
    user: str,
    password: str,
    ui_timeout: int,
    verify_timeout: int,
    key_sequence: Optional[str],
    key_pause: float,
    play_macro_file: Optional[Path],
    manual_2fa: bool,
) -> int:
    forty_exe = _client_executable_path()
    if not forty_exe.exists():
        raise FileNotFoundError(f"No se encontró FortyClient.exe en {forty_exe}")

    _log(f"Abriendo FortyClient para perfil: {vpn_name}")
    subprocess.Popen([str(forty_exe)], shell=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    win = _wait_forty_window(ui_timeout)
    if not win:
        _log("No se pudo detectar la ventana de FortyClient")
        return 1

    win.set_focus()

    macro_reproduced = False
    if play_macro_file:
        if _play_ui_macro(win, play_macro_file, user=user, password=password):
            macro_reproduced = True
            _log("Macro UI reproducida")
        else:
            _log("No se pudo reproducir macro UI; se continúa con flujo estándar")

    if manual_2fa and play_macro_file:
        if macro_reproduced:
            _log("Modo 2FA manual activo con macro reproducida: se omiten pasos automáticos adicionales.")
        else:
            _log("Modo 2FA manual activo: se detiene tras intentar reproducir macro UI.")
        return 0

    if key_sequence:
        _log(f"Ejecutando secuencia de teclas: {key_sequence}")
        _send_key_sequence(key_sequence, key_pause)
        time.sleep(0.5)

    _try_click_remote_access(win)

    selected = _select_vpn_profile(win, vpn_name)
    if not selected:
        _log("No se pudo seleccionar perfil automáticamente; se usa el perfil visible en pantalla")

    try:
        _fill_credentials(win, user, password)
        _click_connect(win)
        _log("Click en Conectar enviado")
    except Exception:
        _fallback_type_and_connect(user, password)
        _log("Conectar enviado por fallback de teclado")

    if manual_2fa:
        _log("Modo 2FA manual activo: se omite verificación de adaptador y se asume éxito de reproducción.")
        return 0

    deadline = time.time() + verify_timeout
    while time.time() < deadline:
        if _is_forty_adapter_up():
            _log("VPN detectada como activa")
            return 0
        time.sleep(2)

    _log("No se detectó adaptador VPN activo en el tiempo esperado")
    return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Automatiza UI de FortyClient/FortyToken")
    parser.add_argument("--vpn-name", default=None, help="Nombre del perfil VPN")
    parser.add_argument("--user", default=None, help="Usuario VPN")
    parser.add_argument("--password", default=None, help="Contraseña VPN")
    parser.add_argument("--ui-timeout", type=int, default=40, help="Timeout para detectar ventana FortyClient")
    parser.add_argument("--verify-timeout", type=int, default=60, help="Timeout para verificar túnel activo")
    parser.add_argument(
        "--key-sequence",
        default=None,
        help="Secuencia de teclas separada por comas (ej: tab,tab,enter)",
    )
    parser.add_argument(
        "--key-pause",
        type=float,
        default=0.15,
        help="Pausa (segundos) entre teclas de --key-sequence",
    )
    parser.add_argument(
        "--record-ui",
        action="store_true",
        help="Graba una macro de acciones UI en FortyClient (finaliza con F8)",
    )
    parser.add_argument(
        "--play-ui",
        default=None,
        help="Ruta a macro UI JSON a reproducir antes del login automático",
    )
    parser.add_argument(
        "--macro-file",
        default=str(_macro_default_path()),
        help="Ruta por defecto para guardar/leer macro UI",
    )
    parser.add_argument(
        "--record-timeout",
        type=int,
        default=300,
        help="Timeout máximo de grabación UI en segundos",
    )
    parser.add_argument(
        "--record-debug",
        action="store_true",
        help="Muestra eventos capturados en tiempo real durante --record-ui",
    )
    parser.add_argument(
        "--manual-2fa",
        action="store_true",
        help="Asume éxito luego de enviar Conectar, para completar segundo factor manualmente",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    project_root = Path(__file__).resolve().parents[1]
    local_cfg_dir = f".{project_root.name}"
    local_cfg = _load_kv_file(Path.home() / local_cfg_dir / "config.txt")
    project_cfg = _load_kv_file(project_root / "config.txt")

    macro_path = Path(args.macro_file)

    if args.record_ui:
        forty_exe = _client_executable_path()
        if not forty_exe.exists():
            raise FileNotFoundError(f"No se encontró FortyClient.exe en {forty_exe}")

        _log("Abriendo FortyClient para grabación UI...")
        subprocess.Popen([str(forty_exe)], shell=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        win = _wait_forty_window(args.ui_timeout)
        if not win:
            _log("No se pudo detectar la ventana de FortyClient para grabar")
            return 1
        win.set_focus()
        return _record_ui_macro(win, macro_path, args.record_timeout, args.record_debug)

    cmd_template = os.getenv("FORTY_VPN_CONNECT_CMD") or local_cfg.get("FORTY_VPN_CONNECT_CMD") or project_cfg.get("FORTY_VPN_CONNECT_CMD", "")
    resolved_exe = os.getenv("FORTY_CLIENT_EXE") or str(_client_executable_path())
    if "{FORTY_CLIENT_EXE}" in cmd_template:
        cmd_template = cmd_template.replace("{FORTY_CLIENT_EXE}", resolved_exe)
    vpn_name = args.vpn_name or _extract_vpn_name_from_cmd(cmd_template)
    user = args.user or os.getenv("FORTY_VPN_USER") or os.getenv("VPN_USERNAME")
    password = args.password or os.getenv("FORTY_VPN_PASSWORD") or os.getenv("VPN_PASSWORD")

    if not vpn_name:
        raise EnvironmentError("No se pudo resolver el nombre VPN. Pásalo por --vpn-name o en FORTY_VPN_CONNECT_CMD")
    if not user or not password:
        raise EnvironmentError("Faltan credenciales VPN. Usa --user/--password o variables FORTY_VPN_USER/FORTY_VPN_PASSWORD")

    play_macro_path = None
    if args.play_ui:
        play_macro_path = Path(args.play_ui)
    elif macro_path.exists():
        play_macro_path = macro_path

    return connect_vpn_ui(
        vpn_name=vpn_name,
        user=user,
        password=password,
        ui_timeout=args.ui_timeout,
        verify_timeout=args.verify_timeout,
        key_sequence=args.key_sequence,
        key_pause=args.key_pause,
        play_macro_file=play_macro_path,
        manual_2fa=args.manual_2fa,
    )


if __name__ == "__main__":
    raise SystemExit(main())
