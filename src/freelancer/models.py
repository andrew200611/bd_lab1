"""Моделі читання — рядки подань (View).

Кожен клас — «знімок» одного подання з sql/05_views.sql. Імена полів мусять
ЗБІГАТИСЯ з іменами колонок подання: psycopg збирає об'єкти автоматично
(class_row), і розходження в імені дасть помилку одразу, а не тихе None.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal


@dataclass(frozen=True, slots=True)
class ActiveProject:
    """Рядок подання v_active_project."""

    p_uid: int
    p_title: str
    p_status: str
    p_pricing_type: str
    p_budget_min: Decimal | None
    p_budget_max: Decimal | None
    p_currency: str
    p_category: str | None
    cp_uid: int
    cp_company_name: str | None
    p_client: str
    p_deadline: date | None
    proposals_count: int
    p_created_at: datetime


@dataclass(frozen=True, slots=True)
class ContractFinance:
    """Рядок подання v_contract_finance — фінансовий стан контракту."""

    ct_uid: int
    ct_status: str
    ct_p_uid: int
    ct_client: str
    ct_freelancer: str
    ct_amount: Decimal
    ct_currency: str
    milestones_total: Decimal
    invoiced: Decimal
    paid: Decimal
    balance: Decimal
    ct_start_date: date
    ct_end_date: date | None
    ct_updated_at: datetime | None


@dataclass(frozen=True, slots=True)
class TaskBoardItem:
    """Рядок подання v_task_board."""

    t_uid: int
    t_ms_uid: int
    ms_title: str
    ms_ct_uid: int
    contract_status: str
    t_title: str
    t_status: str
    t_hours_estimated: Decimal | None
    t_due_date: date | None
    t_fp_uid: int | None
    t_freelancer: str | None
    is_overdue: bool
    t_created_at: datetime
    t_updated_at: datetime | None
