"""Доменні винятки шару доступу до даних.

Процедури піднімають помилки з конкретним SQLSTATE, і застосунку майже
ніколи не потрібен текст повідомлення — потрібно знати КЛАС ситуації.
«Запису немає», «порушено бізнес-правило» і «конфлікт унікальності» — це
три різні реакції на рівні UI: 404, 400 і 409 відповідно.
"""

from __future__ import annotations


class RepositoryError(Exception):
    """Базова помилка шару доступу до даних."""


class GuardViolation(RepositoryError):
    """Спроба обійти архітектурне правило доступу до даних.

    Кидається, коли код звертається до таблиці напряму, а не через View,
    або намагається виконати довільний SQL замість виклику процедури.
    Це помилка ПРОГРАМІСТА, а не користувача.
    """


class NotFound(RepositoryError):
    """Запису немає (SQLSTATE P0002)."""


class BusinessRuleViolation(RepositoryError):
    """Порушено бізнес-правило або унікальність (SQLSTATE 23514 / 23505)."""


# SQLSTATE -> клас винятку. Мапимо КОД, а не текст: текст локалізований
# і може змінитися, а код стабільний.
_SQLSTATE_MAP: dict[str, type[RepositoryError]] = {
    "P0002": NotFound,               # RAISE ... ERRCODE = 'no_data_found'
    "23505": BusinessRuleViolation,  # unique_violation
    "23514": BusinessRuleViolation,  # check_violation
}


def translate(exc: BaseException, sqlstate: str | None) -> RepositoryError:
    """Перетворює помилку psycopg у доменний виняток.

    У повідомлення беремо `message_primary`, а не `str(exc)`: останній
    додає службовий рядок CONTEXT із номером рядка у функції, причому
    мовою сервера. Повний текст лишається доступним у `__cause__`.
    """
    diag = getattr(exc, "diag", None)
    message = getattr(diag, "message_primary", None) or str(exc).strip()
    return _SQLSTATE_MAP.get(sqlstate or "", RepositoryError)(message)
