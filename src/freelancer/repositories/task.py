"""Репозиторій задач.

Читання : v_task_board

Репозиторій лише читає: задачі створюються й закриваються через застосунок
у межах етапів, а окремих процедур для них поки немає.
"""

from __future__ import annotations

from ..models import TaskBoardItem
from .base import BaseRepository

_COLUMNS = (
    "t_uid, t_ms_uid, ms_title, ms_ct_uid, contract_status, t_title, t_status, "
    "t_hours_estimated, t_due_date, t_fp_uid, t_freelancer, is_overdue, "
    "t_created_at, t_updated_at"
)


class TaskRepository(BaseRepository):
    """Задачі в межах етапів."""

    def for_contract(self, ct_uid: int) -> list[TaskBoardItem]:
        """Усі задачі контракту — незалежно від етапу.

        У репозиторії немає жодного JOIN-у: зв'язок «задача -> етап ->
        контракт» уже розкритий у поданні v_task_board.
        """
        sql = (
            f"SELECT {_COLUMNS} FROM v_task_board "
            "WHERE ms_ct_uid = %s ORDER BY t_ms_uid, t_uid"
        )
        return self._fetch(sql, (ct_uid,), model=TaskBoardItem)

    def overdue(self) -> list[TaskBoardItem]:
        """Прострочені задачі — ознаку рахує саме подання, не Python."""
        sql = (
            f"SELECT {_COLUMNS} FROM v_task_board "
            "WHERE is_overdue ORDER BY t_due_date"
        )
        return self._fetch(sql, model=TaskBoardItem)
