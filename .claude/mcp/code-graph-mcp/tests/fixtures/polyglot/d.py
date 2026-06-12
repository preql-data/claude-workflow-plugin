"""d.py — Python def + class + cross-file call chain.

get_current_task() is defined here; pipeline() calls it. We also
import nothing from outside (Python's module resolver needs project
layout we don't replicate in the fixture), so this file is the
self-contained chunk for testing Python coverage.
"""

from helpers import format_label


def get_current_task() -> str:
    return "task-2"


def pipeline() -> str:
    raw = get_current_task()
    return format_label(raw)


class TaskHelper:
    def name(self) -> str:
        return get_current_task()
