"""End-to-end tests of the pty wrapper and the shell integration scripts, with real shells.

Run with:  python3 -m unittest discover -s tests/e2e -v
Needs a debug build of figoterm (swift build --product figoterm).
"""

import faulthandler
import hashlib
import os
import signal
import time
import unittest

from harness import FIGOTERM, SHELL_SCRIPTS, SHELLS, Session

BINDINGS = {
    "enter": "insertSelected",
    "tab": "insertCommonPrefix",
    "up": "navigateUp",
    "down": "navigateDown",
    "shift+tab": "navigateUp",
    "esc": "hideAutocomplete",
    "control+k": "toggleDescription",
    "control+r": "ignore",
}


def intercept(bound=True, global_=True, bindings=BINDINGS):
    return {"intercept": {"_0": {"interceptBound": bound, "interceptGlobal": global_, "bindings": bindings}}}


def replies(session):
    return {reply["id"]: reply["result"] for reply in session.of_kind("reply")}


class WrapperTestCase(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.path.exists(FIGOTERM), f"build figoterm first: {FIGOTERM}")
        self.sessions = []
        # A hang in a test must fail loudly rather than block the whole run.
        faulthandler.dump_traceback_later(90, exit=True)

    def tearDown(self):
        for session in self.sessions:
            session.close()
        faulthandler.cancel_dump_traceback_later()

    def start(self, *args, ready=True, **kwargs):
        session = Session(*args, **kwargs)
        self.sessions.append(session)
        if ready:
            session.wait_prompt()
            session.wait_buffer("")
        return session


class EveryShell(WrapperTestCase):
    """Behaviour that must hold in zsh, bash and fish alike."""

    def each_shell(self):
        for shell in ("zsh", "bash", "fish"):
            if not os.path.exists(SHELLS[shell]):
                continue
            with self.subTest(shell=shell):
                yield shell

    def test_reports_the_command_line_as_it_is_typed(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("git sta")
            s.wait_buffer("git sta")
            s.type("\x7f\x7f")
            s.wait_buffer("git s")
            s.type("\x1b[D\x1b[D")
            s.wait_buffer("git s", cursor=3)

    def test_reports_shell_context(self):
        for shell in self.each_shell():
            s = self.start(shell)
            info = s.of_kind("shell")[-1]["_0"]
            self.assertEqual(info["shell"], shell)
            self.assertEqual(os.path.realpath(info["cwd"]), os.path.realpath(s.home))
            self.assertTrue(os.path.exists(info["shellPath"]))
            self.assertTrue(info["tty"].startswith("/dev/ttys"))
            self.assertNotEqual(info["tty"], s.hello["terminal"]["tty"])
            self.assertGreater(info["pid"], 0)

    def test_command_lifecycle_and_exit_codes(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("printf 'out-%s\\n' 42\r")
            s.wait_prompt(2)
            s.wait_output("out-42")
            s.type("false\r")
            s.wait_prompt(3)
            kinds = [next(iter(m)) for m in s.snapshot() if next(iter(m)) in ("prompt", "preExec", "postExec")]
            self.assertEqual(kinds, ["prompt", "preExec", "postExec", "prompt", "preExec", "postExec", "prompt"])
            self.assertEqual(
                s.of_kind("postExec"),
                [{"command": "printf 'out-%s\\n' 42", "exitCode": 0}, {"command": "false", "exitCode": 1}],
            )

    def test_no_buffer_while_a_command_runs(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("cat\r")
            s.wait(lambda: s.of_kind("preExec"), what="preExec")
            s.clear()
            s.type("typed into cat\r")
            s.wait_output("typed into cat\r\ntyped into cat")
            time.sleep(0.1)
            self.assertEqual(s.edit_buffers(), [])
            s.type("\x04")
            s.wait_prompt()
            s.wait_buffer("")

    def test_private_sequences_never_reach_the_terminal(self):
        for shell in self.each_shell():
            s = self.start(shell, rc="export SECRET_TOKEN=hunter2")
            s.type("echo done\r")
            s.wait_prompt(2)
            self.assertNotIn("6977", s.text())
            self.assertNotIn("hunter2", s.text())

    def test_environment_and_aliases_reflect_the_startup_files(self):
        rc = {
            "zsh": "export FROM_RC=yes\nalias gs='git status'",
            "bash": "export FROM_RC=yes\nalias gs='git status'",
            "fish": "set -gx FROM_RC yes\nalias gs 'git status'",
        }
        for shell in self.each_shell():
            s = self.start(shell, rc=rc[shell])
            environment = s.of_kind("environment")[-1]
            self.assertEqual(environment["variables"]["FROM_RC"], "yes")
            self.assertEqual(environment["variables"]["E2E_MARKER"], "from-outer-environment")
            self.assertIn("gs", environment["aliases"])
            self.assertIn("git status", environment["aliases"])
            # Unchanged environments are not sent again.
            s.type("true\r")
            s.wait_prompt(2)
            self.assertEqual(len(s.of_kind("environment")), 1)
            export = "set -gx LATER 1" if shell == "fish" else "export LATER=1"
            s.type(export + "\r")
            s.wait_prompt(3)
            s.wait(lambda: len(s.of_kind("environment")) == 2, what="second environment")
            self.assertEqual(s.of_kind("environment")[-1]["variables"]["LATER"], "1")

    def test_directory_changes_are_reported(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("cd /usr/share\r")
            s.wait(lambda: s.of_kind("shell")[-1]["_0"]["cwd"] == "/usr/share", what="cwd /usr/share")

    def test_intercepted_keys_go_to_the_app_not_the_shell(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("ech")
            s.wait_buffer("ech")
            s.command(intercept())
            time.sleep(0.05)
            s.clear()
            s.type("\r")
            s.type("\t")
            s.type("\x1b[B")
            s.type("\x1b[Z")
            s.type("\x0b")
            s.wait(lambda: len(s.of_kind("key")) == 5, what="five intercepted keys")
            self.assertEqual(
                [key["action"] for key in s.of_kind("key")],
                ["insertSelected", "insertCommonPrefix", "navigateDown", "navigateUp", "toggleDescription"],
            )
            # None of them reached the shell: the line is unchanged and nothing ran.
            self.assertEqual(s.of_kind("preExec"), [])
            s.type("o")
            s.wait_buffer("echo")

    def test_escape_hides_and_releases_the_keys(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("true")
            s.wait_buffer("true")
            s.command(intercept())
            time.sleep(0.05)
            s.clear()
            s.type("\x1b")
            s.wait(lambda: s.of_kind("key") == [{"action": "hideAutocomplete"}], what="hide action")
            s.type("\r")
            s.wait(lambda: s.of_kind("preExec"), what="command to run after Esc")
            self.assertEqual(len(s.of_kind("key")), 1)

    def test_unbound_and_ignored_keys_pass_through(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.command(intercept())
            time.sleep(0.05)
            s.type("ab")
            s.wait_buffer("ab")
            s.type("\x1b[D")
            s.wait_buffer("ab", cursor=1)
            self.assertEqual(s.of_kind("key"), [])

    def test_interception_stops_when_a_command_starts(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.command(intercept(bindings={"x": "insertSelected"}))
            time.sleep(0.05)
            s.type("cat\r")
            s.wait(lambda: s.of_kind("preExec"), what="preExec")
            s.type("xyz\r")
            s.wait_output("xyz\r\nxyz")
            self.assertEqual(s.of_kind("key"), [])
            s.type("\x04")
            s.wait_prompt(2)

    def test_insertion_types_into_the_shell(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("cd si")
            s.wait_buffer("cd si")
            s.command({"insert": {"text": "\b\bSites/", "insertionBuffer": "cd si"}})
            s.wait_buffer("cd Sites/")
            s.command({"insert": {"text": "--opt= \x1b[D", "insertionBuffer": "cd Sites/"}})
            # zsh reports its line exactly. Elsewhere it is read off the screen, where a space
            # after the cursor cannot be told from blank cells.
            s.wait_buffer("cd Sites/--opt= " if shell == "zsh" else "cd Sites/--opt=", cursor=15)

    def test_insertion_reconciles_with_what_was_typed_meanwhile(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("git chec")
            s.wait_buffer("git chec")
            # The popup computed its insertion when the line was still "git ch".
            s.command({"insert": {"text": "\b\bcheckout ", "insertionBuffer": "git ch"}})
            s.wait_buffer("git checkout ")

    def test_insertion_can_run_the_command(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.type("echo ")
            s.wait_buffer("echo ")
            s.command({"insert": {"text": "ran-it\n", "insertionBuffer": "echo "}})
            s.wait(lambda: s.of_kind("postExec") == [{"command": "echo ran-it", "exitCode": 0}], what="postExec")

    def test_pasted_text_is_never_taken_as_keys(self):
        # A terminal brackets a paste with markers. It can be far larger than one read and
        # arrive in pieces; a Return or Tab inside it belongs to the shell, not to the popup.
        s = self.start("zsh")
        s.type("ech")
        s.wait_buffer("ech")
        s.command(intercept())
        time.sleep(0.05)
        s.clear()
        body = "o " + "word\tword " * 900 + "end"
        paste = "\x1b[200~" + body + "\x1b[201~"
        for offset in range(0, len(paste), 1000):
            s.type(paste[offset : offset + 1000])
            time.sleep(0.03)
        s.wait_buffer("ech" + body, timeout=15)
        self.assertEqual(s.of_kind("key"), [])
        # Afterwards keys are keys again.
        s.type("\t")
        s.wait(lambda: s.of_kind("key") == [{"action": "insertCommonPrefix"}], what="an intercepted tab")

    def test_buffers_say_whether_keys_were_typed(self):
        for shell in self.each_shell():
            s = self.start(shell)

            def typed():
                return [payload["_0"]["typed"] for payload in s.of_kind("editBuffer") if payload.get("_0")]

            # A tab that has just opened has the keyboard.
            self.assertTrue(typed()[0])
            s.type("sleep 0.4\r")
            s.wait(lambda: s.of_kind("preExec"), what="preExec")
            # Typed ahead while the command runs: on the next command line, but not a sign that
            # this tab still has the focus by then.
            s.type("ec")
            s.wait_prompt(2)
            s.wait_buffer("ec")
            self.assertFalse(typed()[-1])
            s.type("h")
            s.wait_buffer("ech")
            self.assertTrue(typed()[-1])

    def test_simulated_input_goes_through_interception(self):
        for shell in self.each_shell():
            s = self.start(shell)
            s.command({"simulateInput": {"text": "pw"}})
            s.wait_buffer("pw")
            s.command(intercept())
            s.command({"simulateInput": {"text": "\r"}})
            s.wait(lambda: s.of_kind("key") == [{"action": "insertSelected"}], what="intercepted enter")

    def test_helper_processes_run_with_the_shell_environment(self):
        rc = {"zsh": "export FROM_RC=rc-value", "bash": "export FROM_RC=rc-value", "fish": "set -gx FROM_RC rc-value"}
        for shell in self.each_shell():
            s = self.start(shell, rc=rc[shell])
            s.type("cd /usr/share\r")
            s.wait_prompt(2)
            request = {
                "executable": "sh",
                "arguments": ["-c", 'printf "%s|%s|%s|%s|" "$FROM_RC" "$EXTRA" "${E2E_MARKER-unset}" "$FIGO_HELPER"; pwd; echo oops >&2; exit 3'],
                "environment": {"EXTRA": "added", "E2E_MARKER": None},
            }
            s.command({"runProcess": {"id": 7, "request": request}})
            result = s.wait(lambda: replies(s).get(7), what="process reply")
            self.assertEqual(
                result,
                {"process": {"_0": {"stdout": "rc-value|added|unset|1|/usr/share\n", "stderr": "oops\n", "exitCode": 3}}},
            )

    def test_helper_process_failures_and_timeouts(self):
        s = self.start("zsh")
        s.command({"runProcess": {"id": 1, "request": {"executable": "no-such-program-xyz", "arguments": [], "environment": {}}}})
        s.command(
            {"runProcess": {"id": 2, "request": {"executable": "sleep", "arguments": ["30"], "environment": {}, "timeoutMilliseconds": 200}}}
        )
        s.command(
            {"runProcess": {"id": 3, "request": {"executable": "pwd", "arguments": [], "environment": {}, "workingDirectory": "/does/not/exist"}}}
        )
        s.wait(lambda: len(replies(s)) == 3, what="three replies")
        self.assertIn("failure", replies(s)[1])
        self.assertIn("timed out", replies(s)[2]["failure"]["_0"])
        # A directory that does not exist falls back to the shell's own.
        self.assertEqual(os.path.realpath(replies(s)[3]["process"]["_0"]["stdout"].strip()), os.path.realpath(s.home))

    def test_directory_listing(self):
        s = self.start("zsh")
        os.mkdir(os.path.join(s.home, "Projects"))
        os.mkdir(os.path.join(s.home, "Projects", "inner"))
        open(os.path.join(s.home, "notes.txt"), "w").close()
        open(os.path.join(s.home, ".hidden"), "w").close()
        os.symlink("Projects", os.path.join(s.home, "link-to-dir"))
        os.symlink("nowhere", os.path.join(s.home, "dangling"))
        s.command({"listDirectory": {"id": 1, "path": "~"}})
        s.command({"listDirectory": {"id": 2, "path": "Projects"}})
        s.command({"listDirectory": {"id": 3, "path": "/definitely/not/here"}})
        s.wait(lambda: len(replies(s)) == 3, what="three replies")

        entries = {entry["name"]: (entry["kind"], entry["isSymlink"]) for entry in replies(s)[1]["directory"]["_0"]}
        self.assertEqual(entries["Projects"], ("directory", False))
        self.assertEqual(entries["notes.txt"], ("file", False))
        self.assertEqual(entries[".hidden"], ("file", False))
        self.assertEqual(entries["link-to-dir"], ("directory", True))
        self.assertEqual(entries["dangling"], ("other", True))
        self.assertNotIn(".", entries)
        self.assertEqual([entry["name"] for entry in replies(s)[2]["directory"]["_0"]], ["inner"])
        self.assertIn("failure", replies(s)[3])


class Robustness(WrapperTestCase):
    def test_exit_status_is_propagated(self):
        s = self.start("zsh")
        s.type("exit 7\r")
        self.assertEqual(s.exit_status(), 7)

    def test_shell_works_without_the_app_and_connects_when_it_appears(self):
        s = self.start("zsh", app=False, ready=False)
        s.wait_output("% ")
        s.type("echo no-app-$((1+1))\r")
        s.wait_output("no-app-2")
        self.assertIsNone(s.hello)

        s.start_app()
        time.sleep(2.1)  # the wrapper spaces out its connection attempts
        s.type("pw")
        s.wait(lambda: s.hello, what="hello after the app started")
        s.wait_buffer("pw")
        self.assertEqual(s.of_kind("shell")[-1]["_0"]["shell"], "zsh")
        self.assertIn("PATH", s.of_kind("environment")[-1]["variables"])

    def test_keys_are_released_when_the_app_goes_away(self):
        s = self.start("zsh")
        s.type("echo back")
        s.wait_buffer("echo back")
        s.command(intercept())
        time.sleep(0.05)
        s.stop_app()
        time.sleep(0.1)
        s.type("\r")
        s.wait_output("\r\nback")

    def test_shell_survives_a_wrapper_crash(self):
        s = self.start("zsh")
        wrapper = s.hello["terminal"]["pid"]
        os.kill(wrapper, signal.SIGSEGV)
        time.sleep(0.2)
        s.type("echo still-$((6*7))\r")
        s.wait_output("still-42")
        s.resize(100, 30)
        time.sleep(0.5)
        s.type("stty size\r")
        s.wait_output("30 100")
        s.type("exit 5\r")
        self.assertEqual(s.exit_status(), 5)

    def test_output_that_empties_the_screen_does_not_stop_the_wrapper(self):
        # Deleting a line on the last row, and scrolling by more than the screen holds, move
        # every row out at once.
        s = self.start("zsh")
        s.type("printf '\\e[24;1H\\e[M\\e[99S\\e[99T\\e[H\\e[99L'; echo done-$((6*7))\r")
        s.wait_output("done-42")
        s.wait_prompt(2)
        s.type("pwd")
        s.wait_buffer("pwd")
        # Private sequences are still being taken out of the output.
        self.assertNotIn("6977", s.text())

    def test_local_bin_is_on_the_path_before_the_rest_of_the_startup_file(self):
        # Startup files written while Fig was installed may call tools from ~/.local/bin.
        rc = {"zsh": 'print "path-ok-${+commands[mytool]}"', "bash": 'type -P mytool >/dev/null && echo path-ok-1', "fish": "type -q mytool; and echo path-ok-1"}
        for shell in ("zsh", "bash", "fish"):
            with self.subTest(shell=shell):
                s = self.start(shell, ready=False, rc=rc[shell], prepare=self.add_local_tool)
                s.wait_output("path-ok-1")

    @staticmethod
    def add_local_tool(home):
        directory = os.path.join(home, ".local", "bin")
        os.makedirs(directory)
        tool = os.path.join(directory, "mytool")
        with open(tool, "w") as file:
            file.write("#!/bin/sh\n")
        os.chmod(tool, 0o755)

    def test_standard_error_reaches_the_terminal(self):
        for shell in ("zsh", "bash", "fish"):
            with self.subTest(shell=shell):
                s = self.start(shell)
                s.type("printf 'to-%s\\n' stderr >&2\r")
                s.wait_output("to-stderr")
                s.type("ls /definitely/not/here\r")
                s.wait_output("No such file or directory")

    def test_window_size_follows_the_terminal(self):
        s = self.start("zsh", columns=90, rows=20)
        s.type("stty size\r")
        s.wait_output("20 90")
        s.resize(120, 33)
        s.wait_prompt(2)
        s.type("stty size\r")
        s.wait_output("33 120")

    def test_typing_before_the_prompt_is_not_lost(self):
        s = self.start("zsh", ready=False, rc="sleep 0.5")
        s.type("echo early-$((2+3))\r")
        s.wait_output("early-5", timeout=10)

    def test_large_output_passes_through_intact(self):
        s = self.start("zsh")
        path = os.path.join(s.home, "big.txt")
        line = "\x1b[32m0123456789 abcdefghijklmnopqrstuvwxyz \x1b]0;title\x07 é漢\U0001f680\x1b[0m\n"
        with open(path, "w") as file:
            file.write(line * 40000)
        expected = hashlib.sha256((line.replace("\n", "\r\n") * 40000).encode()).hexdigest()
        s.type("cat big.txt; echo END-OF-FILE\r")
        s.wait_output("END-OF-FILE\r\n", timeout=30)
        text = s.text()
        start = text.index("\x1b[32m0123456789")
        end = text.index("END-OF-FILE\r\n", start)
        # The kernel's own newline translation on the shell's terminal sometimes emits a second
        # carriage return when a large write is split; it does so without the wrapper too.
        received = text[start:end].replace("\r\r\n", "\r\n")
        self.assertEqual(hashlib.sha256(received.encode()).hexdigest(), expected)

    def test_full_screen_program_retracts_the_buffer(self):
        s = self.start("bash")
        s.type("abc")
        s.wait_buffer("abc")
        s.clear()
        # A readline binding that takes over the screen without running a command.
        s.type("\x15")
        s.wait_buffer("")
        s.type("less /etc/hosts\r")
        s.wait(lambda: s.of_kind("preExec"), what="preExec")
        s.type("q")
        s.wait_prompt()
        s.wait_buffer("")

    def test_not_wrapped_twice_and_not_in_helper_shells(self):
        s = self.start("zsh")
        s.type("echo depth-$FIGO_TERM-; zsh -ic 'echo inner-$FIGO_SESSION_ID-'\r")
        s.wait_output("inner-" + s.hello["terminal"]["sessionId"] + "-")
        s.type("exit\r")
        self.assertEqual(s.exit_status(), 0)

        helper = self.start("zsh", ready=False, app=False, env={"FIGO_HELPER": "1"})
        helper.type("echo wrapped=${FIGO_TERM:-no}\r")
        helper.wait_output("wrapped=no")

    def test_missing_wrapper_leaves_a_plain_shell(self):
        for shell in ("zsh", "bash", "fish"):
            with self.subTest(shell=shell):
                s = self.start(shell, ready=False, app=False, env={"FIGO_TERM_PATH": "/nonexistent/figoterm"})
                s.type("printf 'plain-%s\\n' 9\r")
                s.wait_output("plain-9")


class Zsh(WrapperTestCase):
    def test_multibyte_text_and_cursor(self):
        s = self.start("zsh")
        s.type("echo hé 漢 \U0001f680x")
        s.wait_buffer("echo hé 漢 \U0001f680x", cursor=13)
        s.type("\x1b[D")
        s.wait_buffer("echo hé 漢 \U0001f680x", cursor=12)

    def test_multiline_command(self):
        s = self.start("zsh")
        s.type('echo "a\r')
        s.type("b")
        s.wait_buffer('echo "a\nb')

    def test_right_prompt_and_theme_that_rebuilds_the_prompt(self):
        rc = "\n".join(
            [
                "setopt prompt_subst",
                "precmd() { PS1='[%1~] %# '; RPS1='%T' }",
            ]
        )
        s = self.start("zsh", rc=rc)
        s.type("ls -la")
        s.wait_buffer("ls -la")
        s.type("\r")
        s.wait_prompt(2)
        s.type("pwd")
        s.wait_buffer("pwd")
        self.assertNotIn("6977", s.text())

    def test_survives_strict_options_set_in_the_startup_file(self):
        # With ERR_EXIT a hook that ends on a false test takes the shell down, and KSH_ARRAYS
        # changes what every array subscript means.
        s = self.start("zsh", rc="setopt ERR_EXIT KSH_ARRAYS")
        s.type("echo strict-$((6*7))\r")
        s.wait_output("strict-42")
        s.wait_prompt(2)
        s.type("echo again-$((7*7))")
        s.wait_buffer("echo again-$((7*7))")
        s.type("\r")
        s.wait_output("again-49")
        self.assertEqual([m["command"] for m in s.of_kind("postExec")], ["echo strict-$((6*7))", "echo again-$((7*7))"])

    def test_bash_scripts_sourced_by_zsh_do_nothing(self):
        # ~/.profile gets the bash lines when there is no .bash_profile, and zsh setups source
        # that file too.
        rc = f'source "{SHELL_SCRIPTS}/pre.bash"\nsource "{SHELL_SCRIPTS}/post.bash"'
        s = self.start("zsh", rc=rc)
        s.type("echo fine-$((6*7))\r")
        s.wait_output("fine-42")
        s.wait_prompt(2)
        self.assertEqual(s.of_kind("shell")[-1]["_0"]["shell"], "zsh")
        for complaint in ("bad option", "not found", "shopt"):
            self.assertNotIn(complaint, s.text())

    def test_interrupted_line_starts_empty(self):
        s = self.start("zsh")
        s.type("abandoned")
        s.wait_buffer("abandoned")
        s.type("\x03")
        s.wait_prompt(2)
        s.wait_buffer("")
        self.assertEqual(s.of_kind("postExec"), [])

    def test_history_recall(self):
        s = self.start("zsh")
        s.type("echo first\r")
        s.wait_prompt(2)
        s.type("\x1b[A")
        s.wait_buffer("echo first")

    def test_nested_shell_reports_as_the_same_session(self):
        s = self.start("zsh")
        with open(os.path.join(s.home, ".bashrc"), "w") as file:
            file.write(f"PS1='nested$ '\nsource \"{SHELL_SCRIPTS}/post.bash\"\n")
        s.type("bash --rcfile ~/.bashrc -i\r")
        s.wait(lambda: s.of_kind("shell")[-1]["_0"]["shell"] == "bash", what="nested bash")
        s.type("echo in")
        s.wait_buffer("echo in")
        s.type("\x15exit\r")
        s.wait(lambda: s.of_kind("shell")[-1]["_0"]["shell"] == "zsh", what="back in zsh")
        s.type("pw")
        s.wait_buffer("pw")


class Fish(WrapperTestCase):
    def setUp(self):
        super().setUp()
        if not os.path.exists(SHELLS["fish"]):
            self.skipTest("fish is not installed")

    def test_autosuggestion_ghost_text_is_not_part_of_the_buffer(self):
        s = self.start("fish")
        s.type("echo hello-world\r")
        s.wait_prompt(2)
        s.wait_buffer("")
        s.type("echo h")
        s.wait_buffer("echo h")
        s.wait_output("ello-world")
        time.sleep(0.2)
        self.assertEqual(s.last_buffer(), ("echo h", 6))

    def test_right_prompt_is_excluded(self):
        s = self.start("fish", rc="function fish_right_prompt; printf 'RIGHT'; end")
        s.type("ls")
        s.wait_buffer("ls")

    # What Fig and its successors (Amazon Q, Kiro) do in fish: before every prompt they save the
    # current fish_prompt under their own name and replace it with a wrapper that calls the
    # saved one, and they put the saved one back when a command starts.
    OTHER_WRAPPER = '''
function other_wrap_prompt
    set -l last_status $status
    printf '\\e]697;StartPrompt\\a'
    builtin printf "%b" (string join "\\n" $argv)
    printf '\\e]697;EndPrompt\\a'
    return $last_status
end
function other_precmd --on-event fish_prompt
    if test "$other_has_set_prompt" = 1
        other_preexec
    end
    functions -c fish_prompt other_user_prompt
    function fish_prompt
        other_wrap_prompt (other_user_prompt)
    end
    if functions -q fish_right_prompt
        functions -c fish_right_prompt other_user_right_prompt
        function fish_right_prompt
            other_wrap_prompt (other_user_right_prompt)
        end
    end
    set -g other_has_set_prompt 1
end
function other_preexec --on-event fish_preexec
    functions -e fish_prompt
    functions -c other_user_prompt fish_prompt
    functions -e other_user_prompt
    if functions -q other_user_right_prompt
        functions -e fish_right_prompt
        functions -c other_user_right_prompt fish_right_prompt
        functions -e other_user_right_prompt
    end
    set -g other_has_set_prompt 0
end
'''

    def check_alongside_another_wrapper(self, s):
        s.wait_prompt()
        s.wait_buffer("")
        for round in range(3):
            s.clear()
            s.type("echo round-%d" % round)
            s.wait_buffer("echo round-%d" % round)
            s.type("\r")
            s.wait_prompt()
            s.wait_buffer("")
        self.assertNotIn("call stack limit", s.text())
        self.assertNotIn("Unknown command", s.text())
        # The other tool's markers still reach the terminal, around the user's prompt.
        self.assertIn("\x1b]697;StartPrompt\x07", s.text())
        self.assertIn("> ", s.text())

    def test_works_alongside_a_tool_that_wraps_the_prompt_before_figo(self):
        s = self.start("fish", ready=False, rc=self.OTHER_WRAPPER + "function fish_right_prompt; printf 'RIGHT'; end")
        self.check_alongside_another_wrapper(s)

    def test_works_alongside_a_tool_that_wraps_the_prompt_after_figo(self):
        def add_late_file(home):
            path = os.path.join(home, ".config", "fish", "conf.d", "99_zz_other.fish")
            with open(path, "w") as file:
                file.write(self.OTHER_WRAPPER)

        s = self.start("fish", ready=False, prepare=add_late_file)
        self.check_alongside_another_wrapper(s)

    def test_picks_up_a_prompt_redefined_later(self):
        s = self.start("fish")
        s.type("function fish_prompt; printf 'new-prompt> '; end\r")
        s.wait_prompt(2)
        s.wait_output("new-prompt> ")
        s.type("pwd")
        s.wait_buffer("pwd")


class Bash(WrapperTestCase):
    def test_login_bash_stays_bash(self):
        # A login bash started by name sets $BASH to the account's default shell (zsh on most
        # Macs), which must not decide what the wrapper starts.
        s = self.start("bash", login=True)
        info = s.of_kind("shell")[-1]["_0"]
        self.assertEqual(info["shell"], "bash")
        self.assertTrue(info["shellPath"].endswith("/bash"), info["shellPath"])
        s.type("echo $0-$BASH_VERSINFO")
        s.wait_buffer("echo $0-$BASH_VERSINFO")
        s.type("\r")
        s.wait_output("-bash-")

    def test_prompt_command_that_rebuilds_the_prompt(self):
        s = self.start("bash", rc="PROMPT_COMMAND='PS1=\"[\\W] \\$ \"'")
        s.type("ls -la")
        s.wait_buffer("ls -la")
        s.type("\r")
        s.wait_prompt(2)
        s.type("pwd")
        s.wait_buffer("pwd")

    def test_strict_unset_mode(self):
        # The bash that ships with macOS calls an empty array "unbound" under `set -u`.
        for when in ("before", "after"):
            with self.subTest(set_u=when):
                s = self.start("bash", rc="set -u" if when == "before" else "")
                if when == "after":
                    s.type("set -u\r")
                    s.wait_prompt(2)
                s.type("echo strict-$((6*7))\r")
                s.wait_output("strict-42")
                s.type("echo again-$((7*7))")
                s.wait_buffer("echo again-$((7*7))")
                self.assertNotIn("unbound variable", s.text())
                self.assertIn("echo strict-$((6*7))", [m["command"] for m in s.of_kind("postExec")])

    def test_wrapped_long_line(self):
        s = self.start("bash", columns=30)
        text = "echo one two three four five six seven"
        s.type(text)
        s.wait_buffer(text)


if __name__ == "__main__":
    unittest.main()
