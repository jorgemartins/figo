"""Drives the real pty wrapper with a real shell, playing both the terminal and the Figo app.

The shell is started in a pseudo-terminal with an isolated home directory whose startup files
source Figo's integration scripts. A unix socket in an isolated runtime directory stands in for
the app, so the tests see exactly the messages the app would.
"""

import fcntl
import json
import os
import pty
import select
import shutil
import signal
import socket
import struct
import tempfile
import termios
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIGOTERM = os.environ.get("FIGOTERM", os.path.join(REPO, ".build", "debug", "figoterm"))
SHELL_SCRIPTS = os.path.join(REPO, "shell")

SHELLS = {
    "zsh": "/bin/zsh",
    "bash": "/bin/bash",
    "fish": shutil.which("fish") or "/opt/homebrew/bin/fish",
}


def frame(message):
    payload = json.dumps(message).encode()
    return struct.pack(">I", len(payload)) + payload


class Session:
    """One terminal tab: a shell under the wrapper, plus the app's end of the socket."""

    def __init__(
        self, shell="zsh", rc="", columns=80, rows=24, app=True, shell_path=None, env=None, prepare=None, login=False
    ):
        self.login = login
        self.shell = shell
        self.root = tempfile.mkdtemp(prefix="figo-e2e-")
        self.home = os.path.join(self.root, "home")
        self.runtime = os.path.join(self.root, "run")
        os.makedirs(self.home)
        os.makedirs(self.runtime, mode=0o700)

        self.output = bytearray()
        self.messages = []
        self.hello = None
        self._lock = threading.Lock()
        self._connection = None
        self._buffer = bytearray()
        self._closed = False

        self._listener = None
        if app:
            self.start_app()

        self._write_startup_files(rc)
        if prepare:
            prepare(self.home)
        path = shell_path or SHELLS[shell]
        environment = {
            "HOME": self.home,
            "ZDOTDIR": self.home,
            "XDG_CONFIG_HOME": os.path.join(self.home, ".config"),
            "SHELL": path,
            "USER": os.environ.get("USER", "tester"),
            "LOGNAME": os.environ.get("USER", "tester"),
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "FIGO_RUNTIME_DIR": self.runtime,
            "FIGO_TERM_PATH": FIGOTERM,
            "E2E_MARKER": "from-outer-environment",
        }
        environment.update(env or {})

        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.chdir(self.home)
            arguments = [os.path.basename(path), "-i"]
            if login:
                # How `login` starts a shell: by path, with a dash in front of its name.
                arguments = ["-" + os.path.basename(path)]
            elif shell == "bash":
                arguments = ["bash", "--rcfile", os.path.join(self.home, ".bashrc"), "-i"]
            os.execve(path, arguments, environment)
        self.resize(columns, rows)

        self._thread = threading.Thread(target=self._pump, daemon=True)
        self._thread.start()

    # -- setup ---------------------------------------------------------------------------------

    def _write_startup_files(self, rc):
        if self.shell == "zsh":
            with open(os.path.join(self.home, ".zshrc"), "w") as file:
                file.write(f'source "{SHELL_SCRIPTS}/pre.zsh"\n')
                file.write("PS1='%% '\n")
                file.write(rc + "\n")
                file.write(f'source "{SHELL_SCRIPTS}/post.zsh"\n')
        elif self.shell == "bash":
            # A login bash reads .bash_profile instead of .bashrc.
            with open(os.path.join(self.home, ".bash_profile" if self.login else ".bashrc"), "w") as file:
                file.write(f'source "{SHELL_SCRIPTS}/pre.bash"\n')
                file.write("PS1='$ '\n")
                file.write(rc + "\n")
                file.write(f'source "{SHELL_SCRIPTS}/post.bash"\n')
        elif self.shell == "fish":
            directory = os.path.join(self.home, ".config", "fish", "conf.d")
            os.makedirs(directory)
            with open(os.path.join(directory, "00_figo_pre.fish"), "w") as file:
                file.write(f'source "{SHELL_SCRIPTS}/pre.fish"\n')
            with open(os.path.join(directory, "50_user.fish"), "w") as file:
                file.write("function fish_prompt; printf '> '; end\nfunction fish_greeting; end\n")
                file.write(rc + "\n")
            with open(os.path.join(directory, "99_figo_post.fish"), "w") as file:
                file.write(f'source "{SHELL_SCRIPTS}/post.fish"\n')

    def start_app(self):
        """Starts listening as the app. Can be called later to simulate the app being launched."""
        path = os.path.join(self.runtime, "figo.sock")
        if os.path.exists(path):
            os.unlink(path)
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(path)
        self._listener.listen(4)

    def stop_app(self):
        """Simulates the app quitting."""
        with self._lock:
            if self._connection:
                self._connection.close()
                self._connection = None
            if self._listener:
                self._listener.close()
                self._listener = None
                os.unlink(os.path.join(self.runtime, "figo.sock"))
            self.hello = None

    # -- pump ----------------------------------------------------------------------------------

    def _pump(self):
        while not self._closed:
            with self._lock:
                readable = [self.master]
                if self._listener:
                    readable.append(self._listener)
                if self._connection:
                    readable.append(self._connection)
            try:
                ready, _, _ = select.select(readable, [], [], 0.05)
            except (OSError, ValueError):
                continue
            for item in ready:
                if item == self.master:
                    try:
                        data = os.read(self.master, 65536)
                    except OSError:
                        data = b""
                    if not data:
                        self._closed = True
                        break
                    with self._lock:
                        self.output += data
                    self._answer_queries(data)
                elif item is self._listener:
                    try:
                        connection, _ = self._listener.accept()
                    except OSError:
                        continue
                    with self._lock:
                        self._connection = connection
                        self._buffer = bytearray()
                else:
                    try:
                        data = item.recv(65536)
                    except OSError:
                        data = b""
                    with self._lock:
                        if not data:
                            if self._connection is item:
                                self._connection = None
                            continue
                        self._buffer += data
                        self._decode()

    def _answer_queries(self, data):
        # fish asks the terminal what it is (primary device attributes) and waits for the answer
        # before showing its first prompt, as it would with any real terminal.
        if b"\x1b[0c" in data or b"\x1b[c" in data:
            os.write(self.master, b"\x1b[?62;22c")

    def _decode(self):
        while len(self._buffer) >= 4:
            (length,) = struct.unpack(">I", self._buffer[:4])
            if len(self._buffer) < 4 + length:
                return
            message = json.loads(self._buffer[4 : 4 + length])
            del self._buffer[: 4 + length]
            if "role" in message:
                self.hello = message
            else:
                self.messages.append(message)

    # -- terminal side -------------------------------------------------------------------------

    def resize(self, columns, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def type(self, text):
        data = text.encode() if isinstance(text, str) else text
        while data:
            written = os.write(self.master, data)
            data = data[written:]

    def text(self):
        with self._lock:
            return bytes(self.output).decode(errors="replace")

    # -- app side ------------------------------------------------------------------------------

    def command(self, message):
        with self._lock:
            connection = self._connection
        assert connection is not None, "the wrapper is not connected"
        connection.sendall(frame(message))

    def snapshot(self):
        with self._lock:
            return list(self.messages)

    def clear(self):
        with self._lock:
            self.messages.clear()

    def of_kind(self, kind):
        return [message[kind] for message in self.snapshot() if kind in message]

    def edit_buffers(self):
        """Every edit buffer reported so far, as (text, cursor) or None."""
        result = []
        for payload in self.of_kind("editBuffer"):
            buffer = payload.get("_0")
            result.append(None if buffer is None else (buffer["text"], buffer["cursor"]))
        return result

    def last_buffer(self):
        buffers = self.edit_buffers()
        return buffers[-1] if buffers else "nothing-reported"

    def wait(self, predicate, timeout=5.0, what="condition"):
        deadline = time.time() + timeout
        while time.time() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.01)
        raise AssertionError(
            f"timed out waiting for {what}\n--- messages ---\n"
            + "\n".join(json.dumps(m) for m in self.snapshot()[-25:])
            + "\n--- terminal ---\n"
            + self.text()[-1500:]
        )

    def wait_buffer(self, text, cursor=None, timeout=5.0):
        expected = (text, len(text) if cursor is None else cursor)
        return self.wait(lambda: self.last_buffer() == expected, timeout, f"edit buffer {expected!r}")

    def wait_prompt(self, count=1, timeout=8.0):
        return self.wait(lambda: len(self.of_kind("prompt")) >= count or None, timeout, f"{count} prompt(s)")

    def wait_output(self, needle, timeout=5.0):
        return self.wait(lambda: needle in self.text(), timeout, f"terminal output {needle!r}")

    # -- teardown ------------------------------------------------------------------------------

    def exit_status(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid == self.pid:
                self.pid = None
                return os.waitstatus_to_exitcode(status)
            time.sleep(0.01)
        raise AssertionError("the wrapper did not exit")

    def close(self):
        self._closed = True
        self._thread.join(timeout=1)
        # Closing the terminal hangs up everything attached to it, as closing a tab would.
        try:
            os.close(self.master)
        except OSError:
            pass
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGHUP)
                deadline = time.time() + 2
                while time.time() < deadline:
                    pid, _ = os.waitpid(self.pid, os.WNOHANG)
                    if pid == self.pid:
                        break
                    time.sleep(0.01)
                else:
                    os.kill(self.pid, signal.SIGKILL)
                    os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
        with self._lock:
            if self._connection:
                self._connection.close()
            if self._listener:
                self._listener.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
