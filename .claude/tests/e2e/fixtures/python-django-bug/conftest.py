"""pytest-django conftest for the fixture.

Just enough configuration to load the test settings module so pytest can
discover the `accounts.tests.test_models` cases. Real projects would
use pytest-django; here we keep the module shallow because the harness
prompt is about debugging a failing assertion, not running the test
runner end-to-end.
"""
import os
import sys

import django


def pytest_configure(config):  # noqa: ARG001  pytest plugin contract
    """Boot Django before tests collect so accounts.User can import."""
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
    sys.path.insert(0, os.path.dirname(__file__))
    try:
        django.setup()
    except Exception:
        # If django isn't installed in the environment running this
        # fixture (the harness has no Python venv), fall through — the
        # SDK won't actually invoke pytest, only inspect/edit files.
        pass
