import json, subprocess, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
QUAL = HERE / "qualification.py"

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

if __name__ == "__main__":
    unittest.main()
