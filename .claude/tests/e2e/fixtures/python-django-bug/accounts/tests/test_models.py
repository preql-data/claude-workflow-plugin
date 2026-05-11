"""Test suite for accounts.models.User.

`test_user_email_unique` is the failing test the fixture prompt asks
Claude to fix. It asserts that creating two users with the same email
raises an IntegrityError — but the User model in models.py has
`unique=False` on the email field, so the test fails. Fix is to flip
the constraint and (typically) re-run migrations / acknowledge the
schema delta.
"""
import pytest
from django.db import IntegrityError

from accounts.models import User


@pytest.mark.django_db
def test_user_creation():
    """Smoke test — creating a User succeeds."""
    user = User.objects.create(email="alice@example.com", name="Alice")
    assert user.id is not None
    assert user.email == "alice@example.com"


@pytest.mark.django_db
def test_user_email_unique():
    """Two users cannot share an email address.

    This test is currently FAILING because accounts/models.py declares
    email with unique=False. The prompt asks the orchestrator to fix
    it; the fix is to add the unique constraint.
    """
    User.objects.create(email="bob@example.com", name="Bob")
    with pytest.raises(IntegrityError):
        User.objects.create(email="bob@example.com", name="Bob 2")


@pytest.mark.django_db
def test_user_str():
    """__str__ produces the expected envelope."""
    u = User(email="charlie@example.com")
    assert "charlie@example.com" in str(u)
