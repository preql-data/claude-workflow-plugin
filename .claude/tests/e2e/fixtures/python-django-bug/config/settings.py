"""Minimal Django settings.py for the python-django-bug fixture.

Only enough configuration to make `accounts.User` resolve under the test
runner. INSTALLED_APPS includes the local accounts app; no real
middleware, no production-grade settings.
"""

SECRET_KEY = "fixture-not-a-real-secret-only-used-by-test-runner"
DEBUG = True
INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.auth",
    "accounts",
]
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    }
}
USE_TZ = True
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
