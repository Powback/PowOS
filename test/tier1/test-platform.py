#!/usr/bin/env python3
"""Offline contract/preflight tests. Fake engines; never touch the Docker socket or host registry."""
import copy
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    loader = SourceFileLoader(name, str(filename))
    module = module_from_spec(spec_from_loader(name, loader))
    loader.exec_module(module)
    return module


p = load("platform_test", ROOT / "lib/apps/powos-platform")


def fixture():
    return {"name": "demo", "services": {"web": {
        "image": "demo", "container_name": "demo-web",
        "environment": {"SECRET": "do-not-export-this"},
        "labels": {"io.powos.unit": "demo.web", "powos.autosleep": "on", "powos.autosleep.group": "demo",
                   "powos.autosleep.hibernate": "off", "traefik.docker.allownonrunning": "true",
                   "traefik.http.routers.demo.rule": "Host(`demo.pow`)",
                   "traefik.http.routers.demo.middlewares": "autosleep@file"},
        "volumes": [{"type": "volume", "source": "data", "target": "/data", "read_only": False}]}},
        "x-pow": {"schema": p.SCHEMA, "owner": "user", "host": "powstation", "lifecycleAuthority": "powstation-autosleep",
                  "services": {"web": {"role": "web", "lifecycle": {"policy": "http-idle", "idle": "15m", "group": "demo", "deepSleep": "off"},
                                       "access": {"authentication": "existing", "exposure": "lan-vpn"}}},
                  "datasets": {"data": {"role": "state", "cleanup": "never", "backup": "required", "mounts": [{"service": "web", "target": "/data"}]}}}}


class ContractTests(unittest.TestCase):
    def test_valid_and_secret_free(self):
        model = fixture()
        report = p.inspect_model(model)
        self.assertEqual(report["errors"], [])
        units = p.unit_manifests(model, report, ["-f", "/tmp/project/compose.yaml"])
        self.assertNotIn("do-not-export-this", json.dumps([report, units]))
        self.assertIn("--project-directory " + str(Path('/tmp/project').resolve()), units[0]["remove"]["stop"][0])
        self.assertNotIn("rm", units[0]["remove"])
        u = load("platform_units_test", ROOT / "lib/apps/powos-units")
        self.assertEqual(u.validate(units[0]), [])

    def test_all_mounts_classified(self):
        model = fixture(); model["x-pow"]["datasets"] = {}
        self.assertIn("mount has no dataset declaration", " ".join(p.inspect_model(model)["errors"]))

    def test_borrowed_state_must_be_readonly(self):
        model = fixture(); model["x-pow"]["datasets"]["data"]["role"] = "borrowed-state"
        self.assertIn("read-only", " ".join(p.inspect_model(model)["errors"]))

    def test_state_never_evicted(self):
        model = fixture(); model["x-pow"]["datasets"]["data"]["cleanup"] = "lru"
        self.assertIn("cleanup=never", " ".join(p.inspect_model(model)["errors"]))

    def test_middleware_required_on_every_router(self):
        model = fixture(); model["services"]["web"]["labels"]["traefik.http.routers.other.rule"] = "Host(`other.pow`)"
        self.assertIn("other: missing", " ".join(p.inspect_model(model)["errors"]))

    def test_auth_precedes_wake(self):
        model = fixture(); model["x-pow"]["services"]["web"]["access"]["authentication"] = "powauth"
        labels = model["services"]["web"]["labels"]
        labels["traefik.http.routers.demo.middlewares"] = "autosleep@file,authelia@docker"
        self.assertIn("authenticate before", " ".join(p.inspect_model(model)["errors"]))
        labels["traefik.http.routers.demo.middlewares"] = "authelia@docker,autosleep@file"
        self.assertEqual(p.inspect_model(model)["errors"], [])

    def test_protected_projects_do_not_sleep(self):
        for project in ("powstation", "spacetimeai", "android-app-dev"):
            model = fixture(); model["name"] = project
            self.assertIn("protected", " ".join(p.inspect_model(model)["errors"]))

    def test_state_images_do_not_sleep(self):
        model = fixture(); model["services"]["web"]["image"] = "postgres:16"
        self.assertIn("protected", " ".join(p.inspect_model(model)["errors"]))

    def test_games_and_media_need_activity_adapter(self):
        for role in ("game-server", "media-server", "download-worker", "build-job"):
            model = fixture(); model["x-pow"]["services"]["web"]["role"] = role
            self.assertIn("activity/wake adapter", " ".join(p.inspect_model(model)["errors"]))

    def test_application_lifecycle_cannot_have_generic_sleeper(self):
        model = fixture(); model["x-pow"]["lifecycleAuthority"] = "application"
        self.assertIn("generic sleeper", " ".join(p.inspect_model(model)["errors"]))

    def test_one_controller(self):
        model = fixture(); model["services"]["web"]["labels"]["io.powos.autosleep"] = "idle=900,mode=pause,stop=0"
        self.assertIn("two container", " ".join(p.inspect_model(model)["errors"]))

    def test_cdn_not_pretended(self):
        model = fixture(); model["services"]["web"]["labels"]["powcdn.enable"] = "true"
        self.assertIn("not implemented", " ".join(p.inspect_model(model)["errors"]))

    def test_followers_need_wake_owner(self):
        model = fixture(); model["x-pow"]["services"]["web"]["lifecycle"]["policy"] = "follow-group"
        model["services"]["web"]["labels"]["powos.autosleep.activity"] = "requests"
        self.assertIn("no HTTP wake owner", " ".join(p.inspect_model(model)["errors"]))

    def test_stale_policy_is_error(self):
        model = fixture(); model["x-pow"]["services"]["gone"] = {}
        self.assertIn("missing service gone", " ".join(p.inspect_model(model)["errors"]))

    def test_unmanaged_is_legacy(self):
        model = fixture(); del model["x-pow"]
        self.assertFalse(p.inspect_model(model)["managed"])

    def test_unit_path_traversal_rejected(self):
        model = fixture(); model["services"]["web"]["labels"]["io.powos.unit"] = "../../bad"
        report = p.inspect_model(model)
        with self.assertRaises(p.Failure): p.unit_manifests(model, report, [])

    def test_top_level_policy_survives_engine_service_extensions_removed(self):
        model = fixture(); model["services"]["web"].pop("x-pow", None)
        self.assertEqual(p.inspect_model(model)["errors"], [])

    def test_explicit_unit_wins_over_compose_group(self):
        u = load("units_precedence", ROOT / "lib/apps/powos-units")
        unit = u.norm(p.unit_manifests(fixture(), p.inspect_model(fixture()), [])[0], "/tmp/unit.json")
        container = {"project": "demo", "name": "demo-web", "owner": "demo.web", "state": "running", "status": "Up", "image": "demo", "workdir": "/tmp", "created": "2026-10-26"}
        with patch.object(u, "docker_containers", return_value=[container]):
            rows = u.docker_rows([unit])
        self.assertEqual(rows[0]["id"], "demo.web")
        self.assertEqual(len(rows), 1)


class CliTests(unittest.TestCase):
    def test_global_options(self):
        flags, command, tail = p.split_args(["-f", "one.yml", "-f", "two.yml", "--profile", "prod", "--project-name=x", "up", "-d"])
        self.assertEqual(command, "up"); self.assertEqual(tail, ["-d"])
        self.assertEqual(flags, ["-f", "one.yml", "-f", "two.yml", "--profile", "prod", "--project-name=x"])

    def test_multiple_hosts_in_one_rule(self):
        routes = p.routes({"traefik.http.routers.x.rule": 'Host(`one.pow`, `two.pow`) || Host("three.pow")'})
        self.assertEqual(routes[0]["hosts"], ["one.pow", "two.pow", "three.pow"])

    def test_port_ranges_and_ephemeral_ports(self):
        self.assertTrue(p.port_overlap("10000-10100", "10050"))
        self.assertFalse(p.port_overlap("10000-10100", "10101-10200"))
        self.assertFalse(p.port_overlap("0", "0"))

    def test_compact_options(self):
        self.assertEqual(p.split_args(["-fone.yml", "-pfoo", "up"]), (["-fone.yml", "-pfoo"], "up", []))

    def test_invalid_contract_blocks_mutation(self):
        model = fixture(); model["services"]["web"]["labels"]["powos.autosleep"] = "never"
        with patch.object(p, "load_model", return_value=model), patch.object(p.subprocess, "call") as call, redirect_stdout(io.StringIO()):
            self.assertEqual(p.main(["-f", "test.yml", "up", "-d"]), 1)
            call.assert_not_called()

    def test_options_preserved_for_preflight_and_engine(self):
        argv = ["-f", "test.yml", "--profile", "test", "up", "-d"]
        with patch.dict(os.environ, {"POW_PLATFORM_HOST": "powstation"}), patch.object(p, "load_model", return_value=fixture()) as load_model, patch.object(p, "dns_guard"), patch.object(p.subprocess, "call", return_value=0) as call:
            self.assertEqual(p.main(argv), 0)
            load_model.assert_called_once_with(argv[:4])
            call.assert_called_once_with(p.engine() + argv)

    def test_wrong_host_blocks_deployment(self):
        with patch.dict(os.environ, {"POW_PLATFORM_HOST": "phone"}), patch.object(p, "load_model", return_value=fixture()), patch.object(p.subprocess, "call") as call:
            with self.assertRaisesRegex(p.Failure, "target host mismatch"):
                p.main(["up", "-d"])
            call.assert_not_called()

    def test_readonly_passes_without_render(self):
        with patch.object(p, "load_model") as load_model, patch.object(p.subprocess, "call", return_value=0):
            self.assertEqual(p.main(["logs", "--tail", "10"]), 0)
            load_model.assert_not_called()

    def test_engine_errors_do_not_leak_secrets(self):
        result = subprocess.CompletedProcess([], 1, "SECRET", "token=very-private")
        with patch.object(p.subprocess, "run", return_value=result):
            with self.assertRaises(p.Failure) as caught: p.capture(["docker", "compose", "config"])
        self.assertNotIn("private", str(caught.exception)); self.assertNotIn("SECRET", str(caught.exception))

    def test_dns_checks_every_address(self):
        with patch.dict(os.environ, {"POW_SELF_IP": "192.168.50.100", "POW_COMPOSE_FORCE": "0"}), patch.object(p.shutil, "which", return_value="/usr/bin/dig"), patch.object(p, "capture", return_value="192.168.50.100\n192.168.50.58\n"):
            with self.assertRaisesRegex(p.Failure, "collision"): p.dns_guard(fixture())

    def test_real_wrapper_with_fake_engine(self):
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / "engine.py"
            fake.write_text("import json\nprint(" + repr(json.dumps(fixture())) + ")\n")
            env = {**os.environ, "POW_COMPOSE_ENGINE": sys.executable + " " + str(fake), "HOME": d}
            result = subprocess.run(["bash", str(ROOT / "bin/pow-compose"), "-f", "ignored.yml", "check", "--json"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["project"], "demo")
            self.assertNotIn("do-not-export-this", result.stdout)

    def test_fleet_duplicate_names(self):
        model = fixture()
        other = copy.deepcopy(model); other["name"] = "second"
        with tempfile.TemporaryDirectory() as d:
            manifest = Path(d) / "fleet.json"
            manifest.write_text(json.dumps({"projects": [{"compose": "a.yml"}, {"compose": "b.yml"}]}))
            with patch.object(p, "load_model", side_effect=[model, other]): result = p.fleet(manifest)
        self.assertFalse(result["ok"])
        self.assertTrue(any("duplicate" in e for e in result["errors"]))


if __name__ == "__main__":
    unittest.main()
