"""User model used by the accounts app.

Deliberately seeded with a `unique=False` email field — the prompt asks
Claude to fix the failing `test_user_email_unique` test, which requires
flipping this to `unique=True` (or noticing the missing constraint via the
debugger 5-step framework). The fix is small but the exercise is whether
the orchestrator routes through the @backend specialist + QA gate.
"""
from django.db import models


class User(models.Model):
    """Local User model for the accounts app.

    NOTE: email is intentionally NOT marked unique — that's the bug the
    fixture's failing test surfaces. Real production code should always
    require unique emails when used as a login identifier.
    """

    email = models.EmailField(unique=False)
    name = models.CharField(max_length=100, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        app_label = "accounts"

    def __str__(self) -> str:
        return f"<User {self.email}>"
