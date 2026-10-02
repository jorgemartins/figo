"""Full-stack test without a terminal window: the bundled app (with its web engine and specs),
the pty wrapper and a real zsh, checking what the popup would show through `figo status`.

Run with:  python3 -m unittest discover -s Tests/e2e -v
Needs build/Figo.app (scripts/bundle.sh). Skipped when it has not been built.
"""

import json
import os
import shutil
import subprocess
import time
import unittest

from harness import REPO, Session

BUNDLE = os.path.join(REPO, "build", "Figo.app", "Contents", "MacOS")


@unittest.skipUnless(os.path.exists(os.path.join(BUNDLE, "FigoApp")), "build/Figo.app has not been built")
class FullStack(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A short path: unix socket paths are limited to about a hundred bytes.
        temp = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"]).decode().strip()
        cls.base = os.path.join(temp, f"figo-stack-{os.getpid()}")
        shutil.rmtree(cls.base, ignore_errors=True)
        cls.env = {
            "FIGO_RUNTIME_DIR": cls.base + "/run",
            "FIGO_CONFIG_DIR": cls.base + "/config",
            "FIGO_DATA_DIR": cls.base + "/data",
        }
        for directory in cls.env.values():
            os.makedirs(directory)
        os.chmod(cls.env["FIGO_RUNTIME_DIR"], 0o700)
        # No terminal window exists to measure, so give the popup a caret near a screen corner.
        # Keys are only handed to the popup while it is actually on screen.
        cls.env["FIGO_DEBUG_CARET"] = "40,400,1,15"
        cls.app = subprocess.Popen(
            [os.path.join(BUNDLE, "FigoApp")],
            env={**os.environ, **cls.env},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 10
        while time.time() < deadline and cls.status() is None:
            time.sleep(0.1)
        time.sleep(1.0)  # let the page load and warm its spec cache

    @classmethod
    def tearDownClass(cls):
        cls.figo("quit")
        try:
            cls.app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.app.kill()
        shutil.rmtree(cls.base, ignore_errors=True)

    @classmethod
    def figo(cls, *arguments):
        result = subprocess.run(
            [os.path.join(BUNDLE, "figo"), *arguments], env={**os.environ, **cls.env}, capture_output=True, text=True
        )
        return result.stdout

    @classmethod
    def status(cls):
        try:
            return json.loads(cls.figo("status", "--json"))
        except json.JSONDecodeError:
            return None

    def popup(self):
        status = self.status()
        return json.loads(status["popupState"]) if status and status.get("popupState") else None

    def setUp(self):
        self.session = Session(
            "zsh", app=False, env={**self.env, "FIGO_TERM_PATH": os.path.join(BUNDLE, "figoterm")}
        )
        self.session.wait_output("% ")
        home = self.session.home
        os.makedirs(os.path.join(home, "Sites", "storefront"))
        os.makedirs(os.path.join(home, "Desktop"))
        with open(os.path.join(home, "package.json"), "w") as file:
            json.dump({"name": "fixture", "scripts": {"dev": "vite", "build": "tsc && vite build", "test": "vitest"}}, file)

    def tearDown(self):
        self.session.close()

    def type(self, text):
        # One key at a time, as a person would: several characters at once look like a paste,
        # which deliberately keeps the popup closed.
        for character in text:
            self.session.type(character)
            time.sleep(0.05)

    def wait_popup(self, predicate, what, timeout=8.0):
        deadline = time.time() + timeout
        state = None
        while time.time() < deadline:
            state = self.popup()
            if state and predicate(state):
                return state
            time.sleep(0.1)
        self.fail(f"timed out waiting for {what}; last popup state: {json.dumps(state)[:600]}")

    def names(self, state):
        return [item["name"] for item in state["first"]]

    def test_folders_for_cd(self):
        self.type("cd ")
        state = self.wait_popup(lambda s: s["visible"] and s["count"] >= 2, "folder suggestions")
        self.assertIn("Sites/", self.names(state))
        self.assertIn("Desktop/", self.names(state))
        self.assertTrue(all(item["type"] == "folder" for item in state["first"]))

        self.type("Si")
        state = self.wait_popup(lambda s: s["visible"] and s["selected"] == "Sites/", "Sites/ selected")

        # Accept it with Enter: the wrapper hands the key to the popup, which types the rest.
        self.session.type("\r")
        self.session.wait(
            lambda: (self.status()["sessions"][0].get("editBuffer") or {}).get("text") == "cd Sites/",
            what="the folder to be inserted",
        )
        state = self.wait_popup(lambda s: s["visible"] and "storefront/" in self.names(s), "the folder's contents")
        self.assertEqual(state["first"][0]["description"], "Enter the current directory")
        self.assertNotIn("no such file or directory", self.session.text())

    def test_subcommands_options_and_scripts(self):
        self.type("git ")
        state = self.wait_popup(lambda s: s["visible"] and s["count"] > 20, "git subcommands")
        self.assertIn("add", self.names(state))
        self.assertEqual(state["first"][0]["type"], "subcommand")

        self.type("\x15npm run ")
        state = self.wait_popup(lambda s: s["visible"] and "dev" in self.names(s), "package.json scripts")
        descriptions = {item["name"]: item["description"] for item in state["first"]}
        self.assertEqual(descriptions["build"], "tsc && vite build")

        self.type("\x15ls -")
        state = self.wait_popup(lambda s: s["visible"] and s["count"] > 5, "ls options")
        self.assertTrue(all(item["type"] == "option" for item in state["first"]))

    def test_escape_hides_and_enter_then_runs_the_command(self):
        self.type("echo hello ")
        self.type("\x15git ")
        self.wait_popup(lambda s: s["visible"], "git subcommands")
        self.session.type("\x1b")
        self.wait_popup(lambda s: not s["visible"], "the popup to hide")
        # Esc keeps it hidden for the rest of the line, so Enter belongs to the shell again.
        self.type("\x15printf 'ran-%s' it")
        self.session.type("\r")
        self.session.wait_output("ran-it")
        self.assertFalse(self.status()["popupVisible"])


if __name__ == "__main__":
    unittest.main()
