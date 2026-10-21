"""Шар доступу до даних для «Інтернет-платформи для фрілансерів».

Публічна точка входу — UnitOfWork. Усе інше — деталі реалізації.

Головне архітектурне правило: застосунок не має права
звертатися до таблиць напряму. Читання — лише з подань (v_*), зміни —
лише через збережені процедури (sp_*). Правило перевіряється в коді
модулем guards, а не тримається на дисципліні.
"""

from .config import DbConfig, load_config
from .errors import (
    BusinessRuleViolation,
    GuardViolation,
    NotFound,
    RepositoryError,
)
from .unit_of_work import UnitOfWork

__all__ = [
    "UnitOfWork",
    "DbConfig",
    "load_config",
    "RepositoryError",
    "GuardViolation",
    "NotFound",
    "BusinessRuleViolation",
]
