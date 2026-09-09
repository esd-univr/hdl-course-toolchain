import json, subprocess, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
QUAL = HERE / "qualification.py"
sys.path.insert(0, str(HERE))
import qualification

def run(*args):
    return subprocess.run([sys.executable, str(QUAL), *args],
                          capture_output=True, text=True)

FULL = dict(
    version="v1.3.1", source_commit="a" * 40, tree_clean="1",
    build_inputs_sha256="b" * 64, release_inputs_sha256="c" * 64,
    docker_image_ref="hdl-course-toolchain:latest",
    docker_image_id="sha256:" + "d" * 64,
    sif_path=".out/hdl-course-toolchain.sif", sif_sha256="e" * 64,
    platform="linux/amd64", arch="x86_64",
    doctor_docker="pass", doctor_apptainer="pass",
)

def record_args(out, **over):
    d = {**FULL, **over}
    return ["record", "--out", str(out),
            "--version", d["version"], "--source-commit", d["source_commit"],
            "--tree-clean", d["tree_clean"],
            "--build-inputs-sha256", d["build_inputs_sha256"],
            "--release-inputs-sha256", d["release_inputs_sha256"],
            "--docker-image-ref", d["docker_image_ref"],
            "--docker-image-id", d["docker_image_id"],
            "--sif-path", d["sif_path"], "--sif-sha256", d["sif_sha256"],
            "--platform", d["platform"], "--arch", d["arch"],
            "--doctor-docker", d["doctor_docker"],
            "--doctor-apptainer", d["doctor_apptainer"]]

class RecordTests(unittest.TestCase):
    def test_record_writes_passed_record(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "qualification.json"
            r = run(*record_args(out))
            self.assertEqual(r.returncode, 0, r.stderr)
            rec = json.loads(out.read_text())
            self.assertEqual(rec["schema"], 1)
            self.assertEqual(rec["status"], "passed")
            self.assertEqual(rec["version"], "v1.3.1")
            self.assertEqual(rec["source_tree_clean"], True)
            self.assertTrue(rec["qualified_at"].endswith("Z"))

    def test_record_refuses_dirty_tree(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "qualification.json"
            r = run(*record_args(out, tree_clean="0"))
            self.assertEqual(r.returncode, 2)
            self.assertFalse(out.exists())


class VerifyTests(unittest.TestCase):
    def _record(self, t, **over):
        out = Path(t) / "qualification.json"
        self.assertEqual(run(*record_args(out, **over)).returncode, 0)
        return out

    def _verify_args(self, rec, **over):
        d = dict(version="v1.3.1", version_file="1.3.1", head="a" * 40,
                 tree_clean="1", build_inputs_sha256="b" * 64,
                 release_inputs_sha256="c" * 64, image_id="sha256:" + "d" * 64)
        d.update(over)
        return ["verify", "--record", str(rec),
                "--version", d["version"], "--version-file", d["version_file"],
                "--head", d["head"], "--tree-clean", d["tree_clean"],
                "--build-inputs-sha256", d["build_inputs_sha256"],
                "--release-inputs-sha256", d["release_inputs_sha256"],
                "--image-id", d["image_id"]]

    def test_verify_ok(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            self.assertEqual(run(*self._verify_args(rec)).returncode, 0)

    def test_verify_head_moved(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, head="f" * 40))
            self.assertEqual(r.returncode, 1)
            self.assertIn("source_commit mismatch", r.stdout + r.stderr)

    def test_verify_image_id_mismatch(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, image_id="sha256:" + "9" * 64))
            self.assertEqual(r.returncode, 1)
            self.assertIn("docker_image_id mismatch", r.stdout + r.stderr)

    def test_verify_dirty_now(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, tree_clean="0"))
            self.assertEqual(r.returncode, 1)

    def test_verify_missing_record(self):
        r = run("verify", "--record", "/nonexistent/q.json",
                *self._verify_args(Path("/x"))[3:])
        self.assertEqual(r.returncode, 1)
        self.assertIn("run 'make qualify'", r.stdout + r.stderr)

    def test_verify_version_arg_mismatch(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, version="v9.9.9"))
            self.assertEqual(r.returncode, 1)
            self.assertIn("version mismatch", r.stdout + r.stderr)

    def test_verify_version_file_mismatch(self):
        with tempfile.TemporaryDirectory() as t:
            rec = self._record(t)
            r = run(*self._verify_args(rec, version_file="9.9.9"))
            self.assertEqual(r.returncode, 1)


class GetTests(unittest.TestCase):
    def test_get_field(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "q.json"
            run(*record_args(out))
            r = run("get", "--record", str(out), "--field", "source_commit")
            self.assertEqual(r.returncode, 0)
            self.assertEqual(r.stdout.strip(), "a" * 40)

    def test_get_unknown_field(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "q.json"
            run(*record_args(out))
            r = run("get", "--record", str(out), "--field", "nonexistent")
            self.assertEqual(r.returncode, 2)


class LoadTests(unittest.TestCase):
    def test_load_missing_file(self):
        with self.assertRaises(qualification.QualificationError) as ctx:
            qualification.load("/nonexistent/q.json")
        self.assertIn("run 'make qualify'", str(ctx.exception))

    def test_load_non_dict_json(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "q.json"
            out.write_text("123")
            with self.assertRaises(qualification.QualificationError) as ctx:
                qualification.load(str(out))
            self.assertIn("not a JSON object", str(ctx.exception))

    def test_load_wrong_schema(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "q.json"
            out.write_text('{"schema": 999, "status": "passed"}')
            with self.assertRaises(qualification.QualificationError) as ctx:
                qualification.load(str(out))
            self.assertIn("schema", str(ctx.exception))

    def test_load_not_passed(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "q.json"
            out.write_text('{"schema": 1, "status": "failed"}')
            with self.assertRaises(qualification.QualificationError) as ctx:
                qualification.load(str(out))
            self.assertIn("passed", str(ctx.exception))

if __name__ == "__main__":
    unittest.main()
