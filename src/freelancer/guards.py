"""Стражник архітектурного правила п.7.

ПРАВИЛО ЗАВДАННЯ
    «Усі запити — виключно через збережені процедури та View».

ЧОМУ ЦЕ ОКРЕМИЙ МОДУЛЬ, А НЕ ДОМОВЛЕНІСТЬ
    Домовленість порушується першим же поспішним комітом: комусь треба
    «швиденько» зробити SELECT з таблиці. Тому правило перевіряється
    машинно: кожен запит проходить через BaseRepository, і порушення падає
    з GuardViolation ЩЕ ДО відправки на сервер.
"""

from __future__ import annotations

import re

from .errors import GuardViolation

# Будь-яка DML/DDL-команда в тексті запиту заборонена.
# \b...\b не спрацює на іменах колонок: "updated_at" і "is_deleted"
# не матчаться, бо після "update"/"delete" йде літера, а не межа слова.
_FORBIDDEN = re.compile(
    r"\b(insert|update|delete|merge|truncate|alter|drop|create|grant|revoke|copy|call)\b",
    re.IGNORECASE,
)

# Джерела даних у FROM / JOIN. Кожне мусить бути поданням (v_*).
_RELATION = re.compile(r"\b(?:from|join)\s+([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)

# Імена процедур за угодою проєкту.
_PROCEDURE = re.compile(r"^sp_[a-z0-9_]+$", re.IGNORECASE)


def assert_view_only(sql: str) -> None:
    """Дозволяє лише SELECT із подань v_*."""
    stripped = sql.strip()

    if not stripped.upper().startswith(("SELECT", "WITH")):
        raise GuardViolation(f"Дозволено лише SELECT. Отримано: {stripped[:60]!r}")

    forbidden = _FORBIDDEN.search(stripped)
    if forbidden:
        raise GuardViolation(
            f"У запиті знайдено заборонене слово {forbidden.group(0)!r}. "
            "Зміни даних виконуються лише через процедури sp_*."
        )

    for relation in _RELATION.findall(stripped):
        if not relation.lower().startswith("v_"):
            raise GuardViolation(
                f"Читання з таблиці {relation!r} напряму заборонено. "
                "Створіть подання v_* у sql/05_views.sql."
            )


def assert_procedure(name: str) -> None:
    """Дозволяє лише виклик процедур за угодою sp_*."""
    if not _PROCEDURE.match(name):
        raise GuardViolation(
            f"{name!r} не схоже на ім'я процедури. "
            "Зміни даних виконуються лише через процедури sp_*."
        )
