"""Репозиторій контрактів — центральна сутність бізнес-процесу.

Читання : v_contract_finance
Зміни   : sp_accept_proposal, sp_add_milestone, sp_issue_invoice, sp_register_payment

Саме accept_proposal показує сенс Unit of Work: одна дія зачіпає чотири
таблиці (contract, proposal ×2, project). Якщо вона впаде на середині,
без транзакції база лишилась би в напівзруйнованому стані.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from ..models import ContractFinance
from .base import BaseRepository, to_decimal

_COLUMNS = (
    "ct_uid, ct_status, ct_p_uid, ct_client, ct_freelancer, ct_amount, "
    "ct_currency, milestones_total, invoiced, paid, balance, "
    "ct_start_date, ct_end_date, ct_updated_at"
)


class ContractRepository(BaseRepository):
    """Контракти між замовником і фрілансером."""

    # ------------------------------------------------------------- читання
    def get(self, ct_uid: int) -> ContractFinance | None:
        sql = f"SELECT {_COLUMNS} FROM v_contract_finance WHERE ct_uid = %s"
        return self._fetch_one(sql, (ct_uid,), model=ContractFinance)

    def list_all(self, *, limit: int | None = None) -> list[ContractFinance]:
        sql = f"SELECT {_COLUMNS} FROM v_contract_finance ORDER BY ct_uid"
        if limit is not None:
            return self._fetch(sql + " LIMIT %s", (limit,), model=ContractFinance)
        return self._fetch(sql, model=ContractFinance)

    # --------------------------------------------------------------- зміни
    def accept_proposal(
        self,
        *,
        pr_uid: int,
        start_date: date,
        days: int | None = None,
        amount: Decimal | int | str | None = None,
    ) -> int:
        """Приймає відгук і створює контракт. Повертає ct_uid.

        Побічні ефекти (усе в одній транзакції, усе всередині процедури):
            * відгук -> ACCEPTED;
            * решта відгуків на це замовлення -> REJECTED;
            * замовлення -> IN_PROGRESS.
        """
        return int(
            self._call(
                "sp_accept_proposal",
                (pr_uid, self.actor_uid, start_date, days, to_decimal(amount)),
            )
        )

    def add_milestone(
        self,
        *,
        ct_uid: int,
        title: str,
        amount: Decimal | int | str,
        due_date: date | None = None,
    ) -> int:
        """Додає етап. Повертає ms_uid.

        Процедура сама перевірить, що сума етапів не перевищить суму
        контракту.
        """
        return int(
            self._call(
                "sp_add_milestone",
                (ct_uid, title, to_decimal(amount), due_date, self.actor_uid),
            )
        )

    def issue_invoice(
        self,
        *,
        ct_uid: int,
        number: str,
        amount: Decimal | int | str,
        due_at: date | None = None,
    ) -> int:
        """Виставляє рахунок. Повертає inv_uid.

        inv_number — природний ключ, тож повторний номер дасть
        BusinessRuleViolation, а не тихе дублювання.
        """
        return int(
            self._call(
                "sp_issue_invoice",
                (ct_uid, number, to_decimal(amount), due_at, self.actor_uid),
            )
        )

    def register_payment(
        self,
        *,
        inv_uid: int,
        amount: Decimal | int | str,
        method: str = "CARD",
        external_ref: str | None = None,
    ) -> int:
        """Реєструє платіж. Повертає pay_uid.

        Процедура сама переведе рахунок у PAID, якщо суму зібрано повністю.
        """
        return int(
            self._call(
                "sp_register_payment",
                (inv_uid, to_decimal(amount), method, external_ref, self.actor_uid),
            )
        )
