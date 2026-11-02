"""Checks the fixture wheel the way an installer would, without pip.

Run with `zig build test-python`, which passes the wheel as `--wheel`.
"""

import base64
import csv
import hashlib
import os
import subprocess
import sys
import zipfile


def test_wheel(wheel, tmp_path):
    name, version, python, abi, platform = wheel.stem.split("-")
    assert (name, python, abi) == ("fixture", "py3", "none")
    dist_info = f"{name}-{version}.dist-info"

    with zipfile.ZipFile(wheel) as z:
        assert z.testzip() is None
        members = [i.filename for i in z.infolist()]
        assert members[-1] == f"{dist_info}/RECORD"
        record = list(csv.reader(z.read(f"{dist_info}/RECORD").decode().splitlines()))
        assert sorted(row[0] for row in record) == sorted(members)
        for path, digest, size in record:
            if path == f"{dist_info}/RECORD":
                assert (digest, size) == ("", "")
                continue
            data = z.read(path)
            expected = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            assert (digest, int(size)) == (f"sha256={expected}", len(data)), path

        wheel_file = z.read(f"{dist_info}/WHEEL").decode().splitlines()
        assert f"Tag: py3-none-{platform}" in wheel_file
        assert "Root-Is-Purelib: false" in wheel_file
        metadata = z.read(f"{dist_info}/METADATA").decode().splitlines()
        assert f"Name: {name}" in metadata
        assert f"Version: {version}" in metadata
        assert f"{name}/__init__.py" in members

        z.extractall(tmp_path)

    # A fresh interpreter, so the import comes from the wheel and not from sys.path of this run.
    out = subprocess.run(
        [sys.executable, "-B", "-c", "import fixture; print(fixture.__file__); print(fixture.add(2, 3))"],
        env={**os.environ, "PYTHONPATH": str(tmp_path)},
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    assert out == [str(tmp_path / name / "__init__.py"), "5"]
