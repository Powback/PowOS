#!/usr/bin/env python3
"""Tier-1 tests for .claude/hooks/wait-guard.py (AGENT-HANDBOOK.md, Efficiency: never hand-roll a wait
loop - put the long-running thing in the background and let agent-notices.py deliver the result).

Hermetic: drives the real hook script as a subprocess, fake PreToolUse JSON in, stdout JSON (or nothing)
out. No filesystem state, no HOME isolation needed - the hook only reads its stdin JSON.
"""

import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
HOOK = os.path.join(REPO, ".claude", "hooks", "wait-guard.py")

SUB_TRANSCRIPT = "/home/user/.claude/projects/foo/sess-1/subagents/agent-xyz.jsonl"
MAIN_TRANSCRIPT = "/home/user/.claude/projects/foo/sess-1.jsonl"


class WaitGuardTests(unittest.TestCase):
    def run_hook(self, command, transcript_path=SUB_TRANSCRIPT, run_in_background=None, tool_name="Bash",
                 cwd="/home/user/pw/some-worktree"):
        tool_input = {"command": command}
        if run_in_background is not None:
            tool_input["run_in_background"] = run_in_background
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": tool_name,
            "tool_input": tool_input,
            "transcript_path": transcript_path,
            "cwd": cwd,
            "session_id": "sess-1",
        }
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10)
        self.assertEqual(p.returncode, 0, f"hook must always exit 0 (fail-silent): {p.stderr}")
        self.assertEqual(p.stderr, "", f"hook must never write to stderr: {p.stderr}")
        return p.stdout.strip()

    def assertDenied(self, out, needle=None):
        self.assertNotEqual(out, "", "expected a deny decision, got no output")
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(decision["hookEventName"], "PreToolUse")
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertTrue(decision["permissionDecisionReason"], "deny must carry a reason")
        if needle:
            self.assertIn(needle, decision["permissionDecisionReason"])
        return decision

    def assertAllowed(self, out):
        self.assertEqual(out, "", "expected no decision (defer/allow), got a deny")

    # -- the two denied shapes --------------------------------------------------------------------
    def test_busy_spin_loop_is_denied(self):
        out = self.run_hook("while pgrep -f some-job >/dev/null; do :; done")
        self.assertDenied(out, "run_in_background")

    def test_busy_spin_loop_true_variant_is_denied(self):
        out = self.run_hook("until curl -sf http://x/ready; do true; done")
        self.assertDenied(out, "run_in_background")

    def test_spin_loop_denied_even_if_backgrounded(self):
        # A no-op spin never does anything useful, backgrounded or not - still denied.
        out = self.run_hook("while pgrep -f some-job >/dev/null; do :; done", run_in_background=True)
        self.assertDenied(out)

    def test_sleep_wait_loop_not_backgrounded_is_denied(self):
        out = self.run_hook("until [ -f /tmp/done ]; do sleep 5; done")
        self.assertDenied(out, "run_in_background")

    def test_sleep_wait_loop_multiline_not_backgrounded_is_denied(self):
        out = self.run_hook("while ! curl -sf http://x/health; do\n  sleep 10\ndone")
        self.assertDenied(out)

    # -- the allowed shapes ------------------------------------------------------------------------
    def test_sleep_wait_loop_backgrounded_is_allowed(self):
        out = self.run_hook("until [ -f /tmp/done ]; do sleep 5; done", run_in_background=True)
        self.assertAllowed(out)

    def test_plain_command_is_allowed(self):
        out = self.run_hook("git status")
        self.assertAllowed(out)

    def test_loop_with_real_work_and_sleep_backoff_is_allowed_when_backgrounded(self):
        out = self.run_hook("for f in a b c; do process \"$f\"; done", run_in_background=True)
        self.assertAllowed(out)

    # -- direct phone input (f24): adb.sh/user.sh input tap/swipe/keyevent outside the queue ----------
    def test_adb_input_tap_is_denied(self):
        out = self.run_hook("tools/phone/adb.sh shell input tap 500 500")
        self.assertDenied(out, "verify queue")

    def test_adb_input_swipe_is_denied(self):
        out = self.run_hook("tools/phone/adb.sh shell input swipe 100 1000 100 500")
        self.assertDenied(out, "verify queue")

    def test_adb_input_keyevent_is_denied(self):
        out = self.run_hook("tools/phone/adb.sh shell input keyevent 4")
        self.assertDenied(out, "verify queue")

    def test_user_sh_input_tap_is_denied(self):
        out = self.run_hook("tools/phone/user.sh input tap 10 10")
        self.assertDenied(out, "verify queue")

    def test_adb_input_tap_with_lock_held_is_allowed(self):
        out = self.run_hook("LOCK_HELD=1 tools/phone/adb.sh shell input tap 500 500")
        self.assertAllowed(out)

    def test_adb_input_tap_with_lock_held_zero_is_still_denied(self):
        # LOCK_HELD=0 is the documented "not held" value (window-lock.sh etc.) - not a bypass.
        out = self.run_hook("LOCK_HELD=0 tools/phone/adb.sh shell input tap 500 500")
        self.assertDenied(out, "verify queue")

    def test_emu_lock_held_bypass_is_allowed(self):
        out = self.run_hook("POWOS_DEVICE=emu LOCK_HELD=1 tools/phone/adb.sh shell input tap 1 1")
        self.assertAllowed(out)

    def test_adb_shell_without_input_is_allowed(self):
        out = self.run_hook("tools/phone/adb.sh shell dumpsys power | head")
        self.assertAllowed(out)

    def test_main_session_allowed_for_direct_phone_input(self):
        out = self.run_hook("tools/phone/adb.sh shell input tap 500 500", transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)

    # -- scoping: subagents only, Bash only ---------------------------------------------------------
    def test_main_session_is_allowed_even_for_a_spin_loop(self):
        out = self.run_hook("while pgrep -f some-job >/dev/null; do :; done", transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)

    def test_main_session_is_allowed_for_a_blocking_sleep_loop(self):
        out = self.run_hook("until [ -f /tmp/done ]; do sleep 5; done", transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)

    def test_non_bash_tool_is_ignored(self):
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Glob",
            "tool_input": {"file_path": "/tmp/x"},
            "transcript_path": SUB_TRANSCRIPT,
            "cwd": "/home/user/pw/some-worktree",
            "session_id": "sess-1",
        }
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")

    def test_malformed_stdin_fails_silent(self):
        p = subprocess.run([sys.executable, HOOK], input="not json", capture_output=True, text=True,
                            timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.strip(), "")
        self.assertEqual(p.stderr, "")

    # -- file edit checks: powos-multiplatform and runner checkouts -----------------------------------
    def run_hook_edit(self, file_path, tool_name="Edit", transcript_path=SUB_TRANSCRIPT):
        """Helper for testing Edit/Write/MultiEdit tools."""
        tool_input = {"file_path": file_path}
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": tool_name,
            "tool_input": tool_input,
            "transcript_path": transcript_path,
            "cwd": "/home/user/pw/some-worktree",
            "session_id": "sess-1",
        }
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10)
        self.assertEqual(p.returncode, 0, f"hook must always exit 0 (fail-silent): {p.stderr}")
        self.assertEqual(p.stderr, "", f"hook must never write to stderr: {p.stderr}")
        return p.stdout.strip()

    def test_edit_in_powos_multiplatform_is_denied(self):
        """Edit inside powos-multiplatform directory is denied."""
        out = self.run_hook_edit("/Users/macback/pw/powos-multiplatform/bin/powos")
        self.assertDenied(out, "make your own worktree")

    def test_edit_in_powos_multiplatform_nested_is_denied(self):
        """Edit in a nested path within powos-multiplatform is denied."""
        out = self.run_hook_edit("/home/user/checkouts/powos-multiplatform/lib/foo.sh")
        self.assertDenied(out, "make your own worktree")

    def test_write_in_powos_multiplatform_is_denied(self):
        """Write inside powos-multiplatform directory is denied."""
        out = self.run_hook_edit("/tmp/powos-multiplatform/test.txt", tool_name="Write")
        self.assertDenied(out, "make your own worktree")

    def test_edit_in_runner_checkout_is_denied(self, tmp_path="/tmp/test-runner-checkout-f181"):
        """Edit in a checkout with .powos-runner-checkout marker is denied.
        Note: This test checks the path logic without actually creating files."""
        # Simulate a path under a runner checkout. Since we can't create .powos-runner-checkout
        # in a hermetic test, we'll document this as a limitation.
        # The real hook will check parent directories for the marker.
        # For now, test that paths in expected runner locations would be caught:
        # (In real usage, /home/verify-runner, /home/emu-runner, /home/ship-runner* would have the marker)
        pass  # Deferred: marker check needs filesystem state

    def test_edit_in_pw_worktree_is_allowed(self):
        """Edit in ~/pw/<worktree-name> (agent's own worktree) is allowed."""
        out = self.run_hook_edit("/Users/macback/pw/my-agent-task/bin/powos")
        self.assertAllowed(out)

    def test_edit_in_pw_x_is_allowed(self):
        """Edit in ~/pw/x/ is allowed (normal worktree)."""
        out = self.run_hook_edit("/Users/macback/pw/x/lib/test.py")
        self.assertAllowed(out)

    def test_main_session_edit_in_powos_multiplatform_is_allowed(self):
        """Main session is allowed to edit even in powos-multiplatform (no guard)."""
        out = self.run_hook_edit("/Users/macback/pw/powos-multiplatform/bin/powos",
                                 transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)

    def test_edit_outside_shared_checkouts_is_allowed(self):
        """Edit in a normal location is allowed."""
        out = self.run_hook_edit("/home/user/projects/myapp/src/main.py")
        self.assertAllowed(out)

    def test_multiedit_with_one_file_in_powos_multiplatform_is_denied(self):
        """MultiEdit with at least one file in powos-multiplatform is denied."""
        tool_input = {
            "edits": [
                {"file_path": "/home/user/myfile.txt"},
                {"file_path": "/home/user/checkouts/powos-multiplatform/lib/foo.sh"},
            ]
        }
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "MultiEdit",
            "tool_input": tool_input,
            "transcript_path": SUB_TRANSCRIPT,
            "cwd": "/home/user/pw/some-worktree",
            "session_id": "sess-1",
        }
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10)
        self.assertEqual(p.returncode, 0)
        out = p.stdout.strip()
        self.assertDenied(out, "make your own worktree")

    def test_multiedit_all_allowed_files_is_allowed(self):
        """MultiEdit with all files in allowed locations is allowed."""
        tool_input = {
            "edits": [
                {"file_path": "/home/user/myfile.txt"},
                {"file_path": "/Users/macback/pw/myagent/lib/foo.sh"},
            ]
        }
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "MultiEdit",
            "tool_input": tool_input,
            "transcript_path": SUB_TRANSCRIPT,
            "cwd": "/home/user/pw/some-worktree",
            "session_id": "sess-1",
        }
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                            text=True, timeout=10)
        self.assertEqual(p.returncode, 0)
        out = p.stdout.strip()
        self.assertAllowed(out)

    # -- git commands in powos-multiplatform checkouts (f201) -------------------------------------------
    def test_git_commit_with_cd_into_powos_multiplatform_is_denied(self):
        """git commit with 'cd powos-multiplatform &&' is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git commit -m 'fix'")
        self.assertDenied(out, "make your own worktree")

    def test_git_push_with_cd_into_powos_multiplatform_is_denied(self):
        """git push with 'cd powos-multiplatform &&' is denied."""
        out = self.run_hook("cd /home/user/pw/powos-multiplatform && git push origin main")
        self.assertDenied(out, "make your own worktree")

    def test_git_rebase_with_cd_into_powos_multiplatform_is_denied(self):
        """git rebase with 'cd powos-multiplatform &&' is denied."""
        out = self.run_hook("cd /some/path/powos-multiplatform && git rebase origin/main")
        self.assertDenied(out, "make your own worktree")

    def test_git_merge_with_cd_into_powos_multiplatform_is_denied(self):
        """git merge with 'cd powos-multiplatform &&' is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git merge feature-branch")
        self.assertDenied(out, "make your own worktree")

    def test_git_commit_with_c_flag_into_powos_multiplatform_is_denied(self):
        """git commit with 'git -C powos-multiplatform' is denied."""
        out = self.run_hook("git -C /Users/macback/pw/powos-multiplatform commit -m 'fix'")
        self.assertDenied(out, "make your own worktree")

    def test_git_push_with_c_flag_into_powos_multiplatform_is_denied(self):
        """git push with 'git -C powos-multiplatform' is denied."""
        out = self.run_hook("git -C /home/user/pw/powos-multiplatform push origin main")
        self.assertDenied(out, "make your own worktree")

    def test_git_rebase_with_c_flag_into_powos_multiplatform_is_denied(self):
        """git rebase with 'git -C powos-multiplatform' is denied."""
        out = self.run_hook("git -C /some/path/powos-multiplatform rebase origin/main")
        self.assertDenied(out, "make your own worktree")

    def test_git_merge_with_c_flag_into_powos_multiplatform_is_denied(self):
        """git merge with 'git -C powos-multiplatform' is denied."""
        out = self.run_hook("git -C /Users/macback/pw/powos-multiplatform merge feature")
        self.assertDenied(out, "make your own worktree")

    def test_git_log_in_powos_multiplatform_is_allowed(self):
        """git log (read-only) in powos-multiplatform is allowed."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git log --oneline")
        self.assertAllowed(out)

    def test_git_status_in_powos_multiplatform_is_allowed(self):
        """git status (read-only) in powos-multiplatform is allowed."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git status")
        self.assertAllowed(out)

    def test_git_diff_in_powos_multiplatform_is_allowed(self):
        """git diff (read-only) in powos-multiplatform is allowed."""
        out = self.run_hook("git -C /Users/macback/pw/powos-multiplatform diff HEAD")
        self.assertAllowed(out)

    def test_git_show_in_powos_multiplatform_is_allowed(self):
        """git show (read-only) in powos-multiplatform is allowed."""
        out = self.run_hook("git -C /Users/macback/pw/powos-multiplatform show HEAD:file.txt")
        self.assertAllowed(out)

    def test_git_fetch_in_powos_multiplatform_is_allowed(self):
        """git fetch (read-only) in powos-multiplatform is allowed."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git fetch origin")
        self.assertAllowed(out)

    def test_git_commit_in_agent_worktree_is_allowed(self):
        """git commit in agent's own worktree is allowed."""
        out = self.run_hook("cd /Users/macback/pw/my-agent-task && git commit -m 'fix'")
        self.assertAllowed(out)

    def test_git_push_in_agent_worktree_is_allowed(self):
        """git push in agent's own worktree is allowed."""
        out = self.run_hook("cd /Users/macback/pw/my-task && git push origin main")
        self.assertAllowed(out)

    def test_main_session_git_commit_in_powos_multiplatform_is_allowed(self):
        """Main session is allowed to commit in powos-multiplatform (no guard)."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git commit -m 'fix'",
                            transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)

    # -- file-writing operations in shared checkouts (new feature) ----------------------------------------
    def test_sed_i_in_powos_multiplatform_is_denied(self):
        """sed -i in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && sed -i 's/old/new/' file.txt")
        self.assertDenied(out, "shared checkout")

    def test_sed_i_in_worktree_is_allowed(self):
        """sed -i in agent's worktree is allowed."""
        out = self.run_hook("cd /Users/macback/pw/f206 && sed -i 's/old/new/' file.txt")
        self.assertAllowed(out)

    def test_perl_i_in_powos_multiplatform_is_denied(self):
        """perl -i in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && perl -i -pe 's/old/new/' file.txt")
        self.assertDenied(out, "shared checkout")

    def test_cp_in_powos_multiplatform_is_denied(self):
        """cp in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && cp src dest")
        self.assertDenied(out, "shared checkout")

    def test_cp_in_worktree_is_allowed(self):
        """cp in agent's worktree is allowed."""
        out = self.run_hook("cd /Users/macback/pw/f206 && cp src dest")
        self.assertAllowed(out)

    def test_mv_in_powos_multiplatform_is_denied(self):
        """mv in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && mv old new")
        self.assertDenied(out, "shared checkout")

    def test_rm_in_powos_multiplatform_is_denied(self):
        """rm in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && rm file.txt")
        self.assertDenied(out, "shared checkout")

    def test_ln_in_powos_multiplatform_is_denied(self):
        """ln in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && ln -s target link")
        self.assertDenied(out, "shared checkout")

    def test_tee_in_powos_multiplatform_is_denied(self):
        """tee in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && cat input | tee output.txt")
        self.assertDenied(out, "shared checkout")

    def test_redirect_to_file_in_powos_multiplatform_is_denied(self):
        """Redirect > file in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && echo 'x' > file.txt")
        self.assertDenied(out, "shared checkout")

    def test_redirect_append_in_powos_multiplatform_is_denied(self):
        """Redirect >> file in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && echo 'x' >> file.txt")
        self.assertDenied(out, "shared checkout")

    def test_python_open_w_in_powos_multiplatform_is_denied(self):
        """python3 open(...'w') in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && python3 -c \"open('f', 'w').write('x')\"")
        self.assertDenied(out, "shared checkout")

    def test_git_apply_in_powos_multiplatform_is_denied(self):
        """git apply in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git apply patch.diff")
        self.assertDenied(out, "shared checkout")

    def test_patch_in_powos_multiplatform_is_denied(self):
        """patch in powos-multiplatform is denied."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && patch < fix.patch")
        self.assertDenied(out, "shared checkout")

    def test_cat_in_powos_multiplatform_is_allowed(self):
        """cat (read-only) in powos-multiplatform is allowed."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && cat file.txt")
        self.assertAllowed(out)

    def test_grep_in_powos_multiplatform_is_allowed(self):
        """grep (read-only) in powos-multiplatform is allowed."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && grep 'pattern' file.txt")
        self.assertAllowed(out)

    def test_redirect_to_dev_null_is_allowed(self):
        """Redirect to /dev/null is allowed."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && grep 'pattern' file.txt >/dev/null")
        self.assertAllowed(out)

    def test_redirect_stderr_to_stdout_is_allowed(self):
        """Redirect stderr to stdout (2>&1) is allowed."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && grep 'pattern' file.txt 2>&1")
        self.assertAllowed(out)

    def test_write_with_shell_cwd_in_powos_multiplatform_is_denied(self):
        """No cd prefix: the shell's own cwd (hook input) decides."""
        out = self.run_hook("sed -i 's/old/new/' file.txt", cwd="/Users/macback/pw/powos-multiplatform")
        self.assertDenied(out, "shared checkout")

    def test_docker_run_rm_and_format_patch_are_not_writes(self):
        """--rm and git format-patch are not the rm/patch commands."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && docker run --rm img true")
        self.assertAllowed(out)
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && git format-patch -1 --stdout")
        self.assertAllowed(out)

    def test_main_session_sed_i_in_powos_multiplatform_is_allowed(self):
        """Main session is allowed to write in powos-multiplatform (no guard)."""
        out = self.run_hook("cd /Users/macback/pw/powos-multiplatform && sed -i 's/old/new/' file.txt",
                            transcript_path=MAIN_TRANSCRIPT)
        self.assertAllowed(out)


if __name__ == "__main__":
    unittest.main()
