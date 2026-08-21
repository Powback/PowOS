#!/usr/bin/env python3
"""Test registry, pass/fail, and the verdict artefact.

A scenario declares cases with @test(...). Each case gets the session, asserts
against it, and returns a one-line description of what it actually observed —
that string is the evidence, and a case that cannot produce one is usually a
case that did not check anything.

Three outcomes, kept distinct on purpose:

  PASS  the assertion held
  FAIL  the assertion did not hold — the thing under test is broken
  ERROR the case could not run — the harness or environment is broken

Collapsing ERROR into FAIL is how a rig starts lying: a state channel that
never came up reads as "the feature is broken" and sends you debugging the
wrong program. SKIP is separate again, for preconditions that are legitimately
absent, and a run that is all SKIPs is reported as a non-run, not a success.
"""
from __future__ import annotations

import json
import os
import time
import traceback

PASS, FAIL, ERROR, SKIP = "pass", "fail", "error", "skip"


class Skip(Exception):
    """Raise from a case whose precondition is legitimately absent."""


TESTS = []


def test(name, requires_channel=True):
    """Register a case. `requires_channel` marks cases that need live state."""
    def deco(fn):
        TESTS.append({"name": name, "fn": fn, "requires_channel": requires_channel})
        return fn
    return deco


def reset():
    TESTS.clear()


class Results:
    def __init__(self, game, appid=None, evidence_dir=None):
        self.game = game
        self.appid = appid
        self.evidence_dir = evidence_dir
        self.cases = []
        self.started = time.time()
        self.notes = []

    def record(self, name, status, detail, seconds=0.0, evidence=None):
        self.cases.append({
            "name": name, "status": status, "detail": detail,
            "seconds": round(seconds, 2), "evidence": evidence or [],
        })

    def note(self, text):
        self.notes.append(text)

    def counts(self):
        c = {PASS: 0, FAIL: 0, ERROR: 0, SKIP: 0}
        for case in self.cases:
            c[case["status"]] = c.get(case["status"], 0) + 1
        return c

    @property
    def verdict(self):
        c = self.counts()
        if c[ERROR]:
            return "error"
        if c[FAIL]:
            return "fail"
        if c[PASS] == 0:
            # Everything skipped is not a pass. A rig that reports success
            # without having observed anything is the failure mode this whole
            # subsystem exists to prevent.
            return "not-run"
        return "pass"

    def to_dict(self):
        c = self.counts()
        return {
            "game": self.game,
            "appid": self.appid,
            "verdict": self.verdict,
            "seconds": round(time.time() - self.started, 1),
            "counts": c,
            "cases": self.cases,
            "notes": self.notes,
            "evidence_dir": self.evidence_dir,
        }

    def save(self, path):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2)
        return path

    def render(self, use_color=True):
        g = "\033[0;32m" if use_color else ""
        r = "\033[0;31m" if use_color else ""
        y = "\033[0;33m" if use_color else ""
        d = "\033[2m" if use_color else ""
        n = "\033[0m" if use_color else ""
        mark = {PASS: f"{g}PASS{n}", FAIL: f"{r}FAIL{n}",
                ERROR: f"{r}ERR {n}", SKIP: f"{y}SKIP{n}"}
        out = []
        for case in self.cases:
            out.append(f"  {mark[case['status']]}  {case['name']}")
            if case["detail"]:
                out.append(f"        {d}{case['detail']}{n}")
            for ev in case["evidence"]:
                out.append(f"        {d}evidence: {ev}{n}")
        c = self.counts()
        out.append("")
        out.append(f"  {c[PASS]} passed, {c[FAIL]} failed, "
                   f"{c[ERROR]} errored, {c[SKIP]} skipped "
                   f"-> {self.verdict.upper()}")
        for note in self.notes:
            out.append(f"  {y}note{n}: {note}")
        return "\n".join(out)


def run_all(session, results, log=print):
    """Run every registered case against `session`."""
    channel_live = session.channel.ready() if session.channel else False
    for case in TESTS:
        started = time.time()
        name = case["name"]
        if case["requires_channel"] and not channel_live:
            results.record(name, ERROR,
                           "state channel is not answering — this case cannot "
                           "observe anything, so its result would be meaningless",
                           time.time() - started)
            log(f"[e2e] ERR  {name}: no state channel")
            continue
        try:
            detail = case["fn"](session)
            results.record(name, PASS, detail or "", time.time() - started,
                           session.take_evidence())
            log(f"[e2e] PASS {name}: {detail or ''}")
        except Skip as ex:
            results.record(name, SKIP, str(ex), time.time() - started)
            log(f"[e2e] SKIP {name}: {ex}")
        except AssertionError as ex:
            results.record(name, FAIL, str(ex), time.time() - started,
                           session.take_evidence())
            log(f"[e2e] FAIL {name}: {ex}")
        except Exception as ex:
            results.record(name, ERROR,
                           f"{type(ex).__name__}: {ex}\n"
                           + traceback.format_exc(limit=4),
                           time.time() - started, session.take_evidence())
            log(f"[e2e] ERR  {name}: {type(ex).__name__}: {ex}")
    return results
