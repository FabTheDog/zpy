import pathlib

import pytest


def pytest_addoption(parser):
    parser.addoption("--wheel", type=pathlib.Path, help="wheel checked by test_wheel.py")


@pytest.fixture
def wheel(request):
    path = request.config.getoption("--wheel")
    if path is None:
        pytest.skip("no --wheel given")
    return path
