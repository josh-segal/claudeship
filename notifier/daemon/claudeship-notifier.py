#!/usr/bin/env python3
"""
claudeship-notifier — Universal daemon for claudeship notifications.

Listens on /tmp/claude-notifier.sock for JSON messages from Claude Code hooks,
maintains session state, writes /tmp/claudeship-status.json for bar adapters,
handles interactive dialogs (rofi/wofi/zenity), desktop notifications, and sound.

Bar-agnostic: Waybar, Polybar, i3status-rs, eww, etc. each use a thin adapter
that reads the status JSON file. The daemon signals Waybar via SIGRTMIN+8
for instant updates.

Usage:
    claudeship-notifier              # run daemon (foreground)
    claudeship-notifier --focus      # focus terminal for most recent working session
    claudeship-notifier --usage      # show usage summary
    claudeship-notifier --status     # print current status JSON to stdout
"""

import asyncio
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

# ── Paths ────────────────────────────────────────────────────────────────────

SOCKET_PATH = "/tmp/claude-notifier.sock"
STATUS_PATH = "/tmp/claudeship-status.json"
LOG_PATH = "/tmp/claude-notifier.log"
ACCOUNTS_PATH = Path.home() / ".claude" / "accounts.json"

SPINNER_FRAMES = list("⣾⣽⣻⢿⡿⣟⣯⣷")
DONE_CLEAR_SECONDS = 8

# ── Data structures ──────────────────────────────────────────────────────────


@dataclass
class Session:
    id: str
    cwd: str = ""
    display_name: str = ""
    is_working: bool = False
    current_tool: Optional[str] = None
    current_command: Optional[str] = None
    tool_updated_at: Optional[float] = None
    is_done: bool = False
    done_at: Optional[float] = None
    account: Optional[str] = None


@dataclass
class AgentSession:
    total: int = 0
    completed: int = 0
    agents: list = field(default_factory=list)  # [{id, name, type}]


@dataclass
class PendingInput:
    request_id: str
    question: str
    options: list
    session_name: str = ""
    session_id: Optional[str] = None
    reply_fifo_path: Optional[str] = None


# ── Daemon ───────────────────────────────────────────────────────────────────


class ClaudeshipDaemon:
    def __init__(self):
        self.sessions: dict[str, Session] = {}
        self.agent_sessions: dict[str, AgentSession] = {}
        self.pending_inputs: dict[str, PendingInput] = {}
        self.accounts: dict = {}
        self.spinner_frame: int = 0
        self.spinner_task: Optional[asyncio.Task] = None
        self._done_clear_tasks: dict[str, asyncio.Task] = {}
        self._load_accounts()

    # ── Logging ──────────────────────────────────────────────────────────────

    def log(self, msg: str):
        ts = datetime.now().strftime("%H:%M:%S.%f")[:12]
        line = f"[{ts}] daemon: {msg}\n"
        try:
            with open(LOG_PATH, "a") as f:
                f.write(line)
        except OSError:
            pass

    # ── Account loading ──────────────────────────────────────────────────────

    def _load_accounts(self):
        try:
            data = json.loads(ACCOUNTS_PATH.read_text())
            self.accounts = data.get("accounts", {})
        except (OSError, json.JSONDecodeError):
            self.accounts = {}

    # ── Status file output ───────────────────────────────────────────────────

    def _compute_status(self) -> dict:
        working_sessions = [s for s in self.sessions.values() if s.is_working]
        done_sessions = [s for s in self.sessions.values() if s.is_done]
        working = len(working_sessions)
        total = len(self.sessions)

        # Compute text (mirrors Swift updateStatusTitle logic)
        if self.pending_inputs:
            text = "⁇ claudeship"
            state = "input-pending"
        elif working > 0:
            count_str = f"{working}/{total}"
            # Find most recently updated tool
            recent = None
            for s in working_sessions:
                if s.current_tool and (
                    recent is None
                    or (s.tool_updated_at or 0) > (recent.tool_updated_at or 0)
                ):
                    recent = s
            tool_suffix = ""
            if recent and recent.current_tool:
                cmd = f" {recent.current_command}" if recent.current_command else ""
                tool_suffix = f" — {recent.current_tool}:{cmd}"
            spinner = SPINNER_FRAMES[self.spinner_frame]
            text = f"{spinner} {count_str} claudeship{tool_suffix}"
            state = "working"
        elif done_sessions:
            text = "✓ claudeship"
            state = "done"
        elif total > 0:
            text = f"✳ {total} claudeship"
            state = "idle"
        else:
            text = "✳ claudeship"
            state = "idle"

        # Build sessions list for tooltip
        sessions_list = []
        for s in sorted(self.sessions.values(), key=lambda s: s.display_name):
            agent_groups = []
            if s.id in self.agent_sessions:
                agents = self.agent_sessions[s.id].agents
                if agents:
                    type_counts: dict[str, int] = {}
                    for a in agents:
                        type_counts[a["type"]] = type_counts.get(a["type"], 0) + 1
                    agent_groups = [
                        {"type": t, "count": c}
                        for t, c in sorted(type_counts.items())
                    ]
            sessions_list.append(
                {
                    "id": s.id,
                    "cwd": s.cwd,
                    "display": s.display_name,
                    "working": s.is_working,
                    "tool": s.current_tool,
                    "cmd": s.current_command,
                    "done": s.is_done,
                    "account": s.account,
                    "agent_groups": agent_groups,
                }
            )

        return {
            "text": text,
            "state": state,
            "sessions": sessions_list,
            "working_count": working,
            "total_count": total,
            "has_pending_inputs": bool(self.pending_inputs),
            "spinner_frame": SPINNER_FRAMES[self.spinner_frame],
            "current_tool": (
                working_sessions[-1].current_tool if working_sessions else None
            ),
            "current_cmd": (
                working_sessions[-1].current_command if working_sessions else None
            ),
        }

    def _write_status(self):
        status = self._compute_status()
        try:
            fd, tmp = tempfile.mkstemp(
                dir="/tmp", prefix=".claudeship-status-", suffix=".json"
            )
            with os.fdopen(fd, "w") as f:
                json.dump(status, f)
            os.replace(tmp, STATUS_PATH)
        except OSError as e:
            self.log(f"write_status error: {e}")

    def _signal_bars(self):
        """Signal Waybar to re-run the adapter script."""
        try:
            subprocess.Popen(
                ["pkill", "-SIGRTMIN+8", "waybar"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            pass

    def _update(self):
        """Write status + signal bars. Call after any state change."""
        self._write_status()
        self._signal_bars()

    # ── Spinner ──────────────────────────────────────────────────────────────

    async def _spinner_loop(self):
        try:
            while True:
                await asyncio.sleep(0.1)
                self.spinner_frame = (self.spinner_frame + 1) % len(SPINNER_FRAMES)
                self._update()
        except asyncio.CancelledError:
            pass

    def _update_spinner(self):
        working = any(s.is_working for s in self.sessions.values())
        if working and self.spinner_task is None:
            self.spinner_task = asyncio.get_event_loop().create_task(
                self._spinner_loop()
            )
        elif not working and self.spinner_task is not None:
            self.spinner_task.cancel()
            self.spinner_task = None
            self.spinner_frame = 0

    # ── Message handlers ─────────────────────────────────────────────────────

    def handle_session_register(self, msg: dict):
        session_id = msg.get("session_id", "")
        if not session_id:
            return
        cwd = msg.get("cwd", "")
        display_name = os.path.basename(cwd) if cwd else session_id[:8]
        account = msg.get("account") or None
        self.sessions[session_id] = Session(
            id=session_id,
            cwd=cwd,
            display_name=display_name,
            account=account,
        )
        self.log(f"session_register id={session_id} name='{display_name}'")
        self._update()

    def handle_session_working(self, msg: dict):
        session_id = msg.get("session_id", "")
        if not session_id:
            return
        if session_id not in self.sessions:
            self.sessions[session_id] = Session(
                id=session_id, display_name=session_id[:8]
            )
        self.sessions[session_id].is_working = True
        self.sessions[session_id].is_done = False
        self._update_spinner()
        self._update()

    def handle_session_tool(self, msg: dict):
        session_id = msg.get("session_id", "")
        if session_id not in self.sessions:
            return
        self.sessions[session_id].current_tool = msg.get("tool_name")
        self.sessions[session_id].current_command = msg.get("command_preview")
        self.sessions[session_id].tool_updated_at = time.time()
        self._update()

    def handle_session_thinking(self, msg: dict):
        session_id = msg.get("session_id", "")
        if session_id not in self.sessions:
            return
        s = self.sessions[session_id]
        s.is_working = True
        s.is_done = False
        s.current_tool = None
        s.current_command = None
        self._update_spinner()
        self._update()

    def handle_session_end(self, msg: dict):
        session_id = msg.get("session_id", "")
        if not session_id:
            return
        self.log(f"session_end id={session_id}")
        # Clear pending inputs for this session
        before = len(self.pending_inputs)
        self.pending_inputs = {
            k: v
            for k, v in self.pending_inputs.items()
            if v.session_id != session_id
        }
        if len(self.pending_inputs) < before:
            self.log(
                f"cleared {before - len(self.pending_inputs)} pending input(s) for ended session"
            )
        self.sessions.pop(session_id, None)
        self.agent_sessions.pop(session_id, None)
        # Cancel done-clear task if any
        if session_id in self._done_clear_tasks:
            self._done_clear_tasks.pop(session_id).cancel()
        self._update_spinner()
        self._update()

    def handle_session_idle(self, msg: dict):
        session_id = msg.get("session_id", "")
        if session_id not in self.sessions:
            return
        self.log(f"session_idle id={session_id}")
        s = self.sessions[session_id]
        s.is_working = False
        s.current_tool = None
        s.current_command = None
        self._update_spinner()
        self._update()

    def handle_turn_stop(self, msg: dict):
        session_id = msg.get("session_id", "")
        if not session_id:
            return
        # If subagents are still active, ignore this intermediate stop
        if session_id in self.agent_sessions:
            agents = self.agent_sessions[session_id].agents
            if agents:
                self.log(
                    f"turn_stop ignored for {session_id} — {len(agents)} subagent(s) still active"
                )
                return
        self.agent_sessions.pop(session_id, None)
        self._complete_turn_stop(session_id)

    def _complete_turn_stop(self, session_id: str):
        if session_id in self.sessions:
            s = self.sessions[session_id]
            s.is_working = False
            s.current_tool = None
            s.current_command = None
            s.is_done = True
            s.done_at = time.time()
            self.log(f"session done id={session_id}")
            self._play_sound()
            self._send_notification(
                "Claude done",
                f"Session finished in {s.cwd}" if s.cwd else "Session finished",
            )
        self._update_spinner()
        self._update()

        # Auto-clear done state after 8 seconds
        async def clear_done():
            await asyncio.sleep(DONE_CLEAR_SECONDS)
            if session_id in self.sessions:
                self.sessions[session_id].is_done = False
                self._update()
            self._done_clear_tasks.pop(session_id, None)

        # Cancel existing clear task if any
        if session_id in self._done_clear_tasks:
            self._done_clear_tasks[session_id].cancel()
        self._done_clear_tasks[session_id] = asyncio.get_event_loop().create_task(
            clear_done()
        )

    def handle_session_inputs_clear(self, msg: dict):
        session_id = msg.get("session_id", "")
        if not session_id:
            return
        before = len(self.pending_inputs)
        self.pending_inputs = {
            k: v
            for k, v in self.pending_inputs.items()
            if v.session_id != session_id
        }
        if len(self.pending_inputs) < before:
            self._update()

    def handle_subagent_start(self, msg: dict):
        parent_id = msg.get("parent_session_id", "")
        agent_id = msg.get("session_id", "")
        if not parent_id or not agent_id:
            return
        agent_name = msg.get("agent_name", "")
        agent_type = msg.get("agent_type") or "Subagent"
        self.log(
            f"subagent_start parent={parent_id} agent={agent_id} type='{agent_type}'"
        )
        if parent_id not in self.agent_sessions:
            self.agent_sessions[parent_id] = AgentSession()
        session = self.agent_sessions[parent_id]
        session.total += 1
        session.agents.append(
            {"id": agent_id, "name": agent_name, "type": agent_type}
        )
        self._update()

    def handle_subagent_stop(self, msg: dict):
        agent_id = msg.get("session_id", "")
        parent_id = msg.get("parent_session_id", "")
        if not agent_id or not parent_id:
            return
        if parent_id not in self.agent_sessions:
            self.log(f"subagent_stop with no tracked parent {parent_id}")
            return
        session = self.agent_sessions[parent_id]
        session.completed += 1
        # Remove agent from active list
        agent_name = "Subagent"
        for i, a in enumerate(session.agents):
            if a["id"] == agent_id:
                if a["name"]:
                    agent_name = a["name"]
                session.agents.pop(i)
                break
        self.log(
            f"{agent_name} done ({session.completed}/{session.total}) parent={parent_id}"
        )
        # Clean up when all subagents done
        if not session.agents:
            self.agent_sessions.pop(parent_id, None)
        self._update()

    def handle_input_question(self, msg: dict):
        request_id = msg.get("request_id", "")
        options = msg.get("options", [])
        if not request_id or not options:
            return
        question = msg.get("question", "Claude needs your input")
        session_id = msg.get("session_id")
        session_name = ""
        if session_id and session_id in self.sessions:
            session_name = self.sessions[session_id].display_name
        elif "subtitle" in msg:
            session_name = msg["subtitle"]
        reply_fifo = msg.get("reply_fifo")

        self.log(f"input_question id={request_id} options={options}")

        self.pending_inputs[request_id] = PendingInput(
            request_id=request_id,
            question=question,
            options=options,
            session_name=session_name,
            session_id=session_id,
            reply_fifo_path=reply_fifo,
        )
        self._update()

        # Spawn dialog in background
        asyncio.get_event_loop().create_task(
            self._show_dialog(request_id, question, options, reply_fifo, session_name)
        )

    def handle_accounts_changed(self, msg: dict):
        self.log("accounts_changed — reloading configs")
        self._load_accounts()
        self._update()

    # ── Permission/input dialogs via native notifications ───────────────────

    async def _show_dialog(
        self,
        request_id: str,
        question: str,
        options: list[str],
        reply_fifo: Optional[str],
        session_name: str = "",
    ):
        """Show permission/input prompt via native notification actions.

        Uses notify-send -A which works with any notification daemon
        (mako, dunst, swaync, etc.). The notification shows the question
        as the title with clickable action buttons for each option.
        """
        chosen = await self._notify_send_actions(question, options, reply_fifo, session_name)

        if chosen:
            self.log(f"dialog reply: '{chosen}' for request {request_id}")
            self._write_reply(request_id, chosen, reply_fifo)
        else:
            self.log(f"dialog timeout/cancelled for request {request_id}")

        # Remove from pending
        self.pending_inputs.pop(request_id, None)
        self._update()

    async def _notify_send_actions(
        self, question: str, options: list[str], reply_fifo: Optional[str] = None,
        session_name: str = "",
    ) -> Optional[str]:
        """Show notification with action buttons via notify-send -A.

        Works with any freedesktop-compliant notification daemon.
        Returns the selected option text, or None on timeout/dismiss.
        """
        if not shutil.which("notify-send"):
            self.log("notify-send not found, cannot show dialog")
            return None
        try:
            title = f"Claude Code — {session_name}" if session_name else "Claude Code"
            # ZWS in digit runs prevents swaync/etc from auto-generating COPY buttons
            body = re.sub(r'(\d{3})(\d)', '\\1\u200b\\2', question)
            cmd = [
                "notify-send",
                title,
                body,
                "--wait",
                "--urgency=critical",
                "--app-name=claudeship",
            ]
            for i, opt in enumerate(options):
                cmd.extend(["-A", f"{i}={opt}"])

            timeout = 30 if reply_fifo else 600

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
            if proc.returncode == 0 and stdout:
                idx_str = stdout.decode().strip()
                try:
                    idx = int(idx_str)
                    if 0 <= idx < len(options):
                        return options[idx]
                except ValueError:
                    pass
        except asyncio.TimeoutError:
            self.log(f"notification timed out after {timeout}s")
        except OSError as e:
            self.log(f"notify-send error: {e}")
        return None

    def _write_reply(
        self, request_id: str, content: str, reply_fifo: Optional[str]
    ):
        """Write the user's choice back to the hook script."""
        if reply_fifo:
            try:
                with open(reply_fifo, "w") as f:
                    f.write(content + "\n")
                self.log(f"wrote reply '{content}' → {reply_fifo}")
            except OSError as e:
                self.log(f"FIFO write error: {e}")
        else:
            reply_path = f"/tmp/claude-input-reply-{request_id}"
            try:
                with open(reply_path, "w") as f:
                    f.write(content)
                self.log(f"wrote reply '{content}' → {reply_path}")
            except OSError as e:
                self.log(f"reply write error: {e}")

    # ── Desktop notifications ────────────────────────────────────────────────

    def _send_notification(self, title: str, body: str):
        if not shutil.which("notify-send"):
            return
        try:
            subprocess.Popen(
                ["notify-send", title, body, "-t", "5000"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass

    # ── Sound ────────────────────────────────────────────────────────────────

    def _play_sound(self):
        # Try to find a completion sound
        sound_file = None
        candidates = [
            "/usr/share/sounds/freedesktop/stereo/complete.oga",
            "/usr/share/sounds/freedesktop/stereo/message.oga",
            "/usr/share/sounds/gnome/default/alerts/glass.ogg",
        ]
        for c in candidates:
            if os.path.exists(c):
                sound_file = c
                break

        if sound_file:
            for player in ("pw-play", "paplay", "aplay"):
                if shutil.which(player):
                    try:
                        subprocess.Popen(
                            [player, sound_file],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                        )
                    except OSError:
                        continue
                    return

        # Fallback: canberra-gtk-play with themed event
        if shutil.which("canberra-gtk-play"):
            try:
                subprocess.Popen(
                    ["canberra-gtk-play", "-i", "complete"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except OSError:
                pass

    # ── Window focus ─────────────────────────────────────────────────────────

    @staticmethod
    def _build_process_tree() -> dict[int, list[int]]:
        """Build a parent-pid -> [child-pids] map from /proc."""
        children: dict[int, list[int]] = {}
        try:
            for entry in os.listdir("/proc"):
                if not entry.isdigit():
                    continue
                try:
                    stat = Path(f"/proc/{entry}/stat").read_text()
                    # ppid is 4th field; handle comm with spaces by splitting after ')'
                    rest = stat.split(")")[-1].split()
                    ppid = int(rest[1])  # fields: state, ppid, ...
                    children.setdefault(ppid, []).append(int(entry))
                except (OSError, ValueError, IndexError):
                    continue
        except OSError:
            pass
        return children

    @staticmethod
    def _pid_tree_has_cwd(pid: int, cwd: str, tree: dict[int, list[int]], depth: int = 0) -> bool:
        """Check if a process or any descendant has an exact CWD match."""
        if depth > 10:
            return False
        try:
            proc_cwd = os.readlink(f"/proc/{pid}/cwd")
            if proc_cwd == cwd:
                return True
        except OSError:
            pass
        for child in tree.get(pid, []):
            if ClaudeshipDaemon._pid_tree_has_cwd(child, cwd, tree, depth + 1):
                return True
        return False

    def focus_terminal(self, cwd: Optional[str] = None):
        """Focus the terminal window whose process tree contains the given CWD."""
        if not cwd:
            working = [s for s in self.sessions.values() if s.is_working]
            if working:
                cwd = working[-1].cwd
            elif self.sessions:
                cwd = list(self.sessions.values())[-1].cwd
        if not cwd:
            return

        hypr_sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
        swaysock = os.environ.get("SWAYSOCK")
        proc_tree = self._build_process_tree()

        if hypr_sig:
            try:
                result = subprocess.run(
                    ["hyprctl", "clients", "-j"],
                    capture_output=True, text=True, timeout=2,
                )
                for client in json.loads(result.stdout):
                    pid = client.get("pid", 0)
                    if pid and self._pid_tree_has_cwd(pid, cwd, proc_tree):
                        addr = client.get("address", "")
                        if addr:
                            subprocess.run(
                                ["hyprctl", "dispatch", "focuswindow", f"address:{addr}"],
                                timeout=2,
                            )
                            return
            except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
                pass
        elif swaysock:
            try:
                result = subprocess.run(
                    ["swaymsg", "-t", "get_tree"],
                    capture_output=True, text=True, timeout=2,
                )
                con_id = self._find_sway_window(json.loads(result.stdout), cwd, proc_tree)
                if con_id:
                    subprocess.run(["swaymsg", f'[con_id="{con_id}"] focus'], timeout=2)
            except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
                pass

    def _find_sway_window(self, node: dict, cwd: str, proc_tree: dict[int, list[int]]) -> Optional[int]:
        """Recursively search the Sway tree for a window matching the CWD."""
        pid = node.get("pid", 0)
        if pid and self._pid_tree_has_cwd(pid, cwd, proc_tree):
            return node.get("id")
        for child in node.get("nodes", []) + node.get("floating_nodes", []):
            result = self._find_sway_window(child, cwd, proc_tree)
            if result:
                return result
        return None

    # ── Socket server ────────────────────────────────────────────────────────

    HANDLERS = {
        "session_register": "handle_session_register",
        "session_working": "handle_session_working",
        "session_tool": "handle_session_tool",
        "session_thinking": "handle_session_thinking",
        "session_end": "handle_session_end",
        "session_idle": "handle_session_idle",
        "turn_stop": "handle_turn_stop",
        "input_question": "handle_input_question",
        "session_inputs_clear": "handle_session_inputs_clear",
        "subagent_start": "handle_subagent_start",
        "subagent_stop": "handle_subagent_stop",
        "accounts_changed": "handle_accounts_changed",
    }

    async def handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ):
        try:
            data = await asyncio.wait_for(reader.read(65536), timeout=5)
        except (asyncio.TimeoutError, ConnectionError):
            writer.close()
            return
        writer.close()

        if not data:
            return

        try:
            msg = json.loads(data)
        except json.JSONDecodeError:
            return

        msg_type = msg.get("type", "")
        handler_name = self.HANDLERS.get(msg_type)
        if handler_name:
            handler = getattr(self, handler_name)
            handler(msg)

    # run() removed — daemon lifecycle is managed by run_daemon() in main()


# ── CLI entry points ─────────────────────────────────────────────────────────


def cmd_focus(selection: str = ""):
    """Focus the terminal for a session. Optionally match by display name."""
    try:
        with open(STATUS_PATH) as f:
            status = json.load(f)
    except (OSError, json.JSONDecodeError):
        print("No active sessions", file=sys.stderr)
        sys.exit(1)

    sessions = status.get("sessions", [])
    if not sessions:
        print("No active sessions", file=sys.stderr)
        sys.exit(1)

    target = None
    if selection:
        for s in sessions:
            if s.get("display", "") in selection:
                target = s
                break
    if not target:
        working = [s for s in sessions if s.get("working")]
        target = working[0] if working else sessions[-1]

    cwd = target.get("cwd", "")
    if not cwd:
        sys.exit(1)

    daemon = ClaudeshipDaemon()
    daemon.focus_terminal(cwd)


def cmd_panel():
    """Output session details in dmenu-compatible format (one line per session).

    Pipe to your preferred launcher:
        claudeship-notifier --panel | rofi -dmenu -p claudeship
        claudeship-notifier --panel | wofi --dmenu
        claudeship-notifier --panel | fuzzel --dmenu
    """
    try:
        with open(STATUS_PATH) as f:
            status = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error reading status: {e}", file=sys.stderr)
        status = {}

    sessions = status.get("sessions", [])
    if not sessions:
        print("no active sessions")
        return

    for s in sessions:
        if s.get("working"):
            icon = "●"
            tool = f"  {s['tool']}:{s.get('cmd', '')}" if s.get("tool") else ""
        elif s.get("done"):
            icon = "✓"
            tool = ""
        else:
            icon = "○"
            tool = ""
        account = f"[{s['account']}] " if s.get("account") else ""
        line = f"{icon} {account}{s['display']}{tool}"
        # Subagent info on same line
        for g in s.get("agent_groups", []):
            count = f" ×{g['count']}" if g["count"] > 1 else ""
            line += f"  ↳ {g['type']}{count}"
        print(line)


def cmd_status():
    """Print current status JSON to stdout."""
    try:
        print(Path(STATUS_PATH).read_text())
    except OSError:
        print("{}")


def cmd_usage():
    """Show usage summary by running the plugin's usage.py."""
    # Find the plugin root by looking relative to this script
    script_dir = Path(__file__).resolve().parent.parent
    usage_py = script_dir / "plugins" / "claudeship" / "src" / "tools" / "usage.py"
    if usage_py.exists():
        os.execvp("python3", ["python3", str(usage_py)])
    else:
        print("usage.py not found", file=sys.stderr)
        sys.exit(1)


def main():
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "--focus":
            cmd_focus(sys.argv[2] if len(sys.argv) > 2 else "")
            return
        elif cmd == "--panel":
            cmd_panel()
            return
        elif cmd == "--status":
            cmd_status()
            return
        elif cmd == "--usage":
            cmd_usage()
            return
        elif cmd in ("-h", "--help"):
            print(__doc__)
            return
        else:
            print(f"Unknown option: {cmd}", file=sys.stderr)
            sys.exit(1)

    # Run the daemon
    daemon = ClaudeshipDaemon()

    async def run_daemon():
        shutdown_event = asyncio.Event()

        def request_shutdown():
            shutdown_event.set()

        loop = asyncio.get_event_loop()
        loop.add_signal_handler(signal.SIGTERM, request_shutdown)
        loop.add_signal_handler(signal.SIGINT, request_shutdown)

        # Clean up stale socket
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass

        daemon._write_status()
        server = await asyncio.start_unix_server(
            daemon.handle_client, path=SOCKET_PATH
        )
        os.chmod(SOCKET_PATH, 0o666)
        daemon.log(f"daemon listening on {SOCKET_PATH}")
        print(
            f"claudeship-notifier: listening on {SOCKET_PATH}", file=sys.stderr
        )

        await shutdown_event.wait()

        # Graceful cleanup
        server.close()
        await server.wait_closed()
        if daemon.spinner_task:
            daemon.spinner_task.cancel()
            try:
                await daemon.spinner_task
            except asyncio.CancelledError:
                pass
        for task in daemon._done_clear_tasks.values():
            task.cancel()
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
        try:
            os.unlink(STATUS_PATH)
        except FileNotFoundError:
            pass

    try:
        asyncio.run(run_daemon())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
