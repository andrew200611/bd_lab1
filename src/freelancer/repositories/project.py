"""Репозиторій замовлень і відгуків.

Читання : v_active_project
Зміни   : sp_create_project, sp_submit_proposal
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from ..models import ActiveProject
from .base import BaseRepository, to_decimal

# Перелік колонок виписаний явно, а не через SELECT *.
# Так видно, від яких саме полів подання залежить репозиторій, і зміна
# подання не ламає код несподівано.
_COLUMNS = (
    "p_uid, p_title, p_status, p_pricing_type, p_budget_min, p_budget_max, "
    "p_currency, p_category, cp_uid, cp_company_name, p_client, p_deadline, "
    "proposals_count, p_created_at"
)


class ProjectRepository(BaseRepository):
    """Замовлення, опубліковані замовниками."""

    # ------------------------------------------------------------- читання
    def list_active(self, *, limit: int | None = None) -> list[ActiveProject]:
        """Активні замовлення, найсвіжіші — першими."""
        sql = (
            f"SELECT {_COLUMNS} FROM v_active_project "
            "ORDER BY p_created_at DESC, p_uid DESC"
        )
        if limit is not None:
            return self._fetch(sql + " LIMIT %s", (limit,), model=ActiveProject)
        return self._fetch(sql, model=ActiveProject)

    def get(self, p_uid: int) -> ActiveProject | None:
        sql = f"SELECT {_COLUMNS} FROM v_active_project WHERE p_uid = %s"
        return self._fetch_one(sql, (p_uid,), model=ActiveProject)

    def count_active(self) -> int:
        return int(self._fetch_scalar("SELECT count(*) FROM v_active_project"))

    # --------------------------------------------------------------- зміни
    def create(
        self,
        *,
        cp_uid: int,
        title: str,
        description: str,
        pricing_type: str,
        budget_min: Decimal | int | str | None,
        budget_max: Decimal | int | str | None,
        currency_uid: int,
        deadline: date | None = None,
        cat_uid: int | None = None,
    ) -> int:
        """Публікує замовлення. Повертає p_uid."""
        return int(
            self._call(
                "sp_create_project",
                (
                    cp_uid, cat_uid, title, description, pricing_type,
                    to_decimal(budget_min), to_decimal(budget_max),
                    currency_uid, deadline, self.actor_uid,
                ),
            )
        )

    def submit_proposal(
        self,
        *,
        p_uid: int,
        fp_uid: int,
        cover_letter: str,
        bid_amount: Decimal | int | str,
        currency_uid: int,
        days: int | None = None,
    ) -> int:
        """Подає відгук на замовлення. Повертає pr_uid.

        Процедура сама перевірить, що замовлення у статусі OPEN і що цей
        фрілансер ще не подавав відгук — тому окремих перевірок тут немає
        і бути не повинно.
        """
        return int(
            self._call(
                "sp_submit_proposal",
                (
                    p_uid, fp_uid, cover_letter, to_decimal(bid_amount),
                    currency_uid, days, self.actor_uid,
                ),
            )
        )
