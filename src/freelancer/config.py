"""Параметри підключення до БД.

Пароль свідомо НЕ має значення за замовчуванням: тримати пароль у коді —
погана звичка, навіть у навчальному проєкті. Якщо змінну не задано, краще
впасти одразу зі зрозумілим текстом, ніж мовчки підключитися не туди.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class DbConfig:
    host: str
    port: int
    dbname: str
    user: str
    password: str

    def dsn(self) -> str:
        """Рядок підключення для psycopg."""
        return (
            f"host={self.host} port={self.port} dbname={self.dbname} "
            f"user={self.user} password={self.password}"
        )


def load_config() -> DbConfig:
    """Збирає конфігурацію зі змінних середовища.

    Змінні:
        FP_DB_HOST, FP_DB_PORT, FP_DB_NAME, FP_DB_USER, FP_DB_PASSWORD
    """
    password = os.getenv("FP_DB_PASSWORD")
    if not password:
        raise RuntimeError(
            "Не задано FP_DB_PASSWORD. Приклад запуску:\n"
            '  FP_DB_PASSWORD=ВАШ_ПАРОЛЬ python src/demo_lifecycle.py'
        )

    return DbConfig(
        host=os.getenv("FP_DB_HOST", "127.0.0.1"),
        port=int(os.getenv("FP_DB_PORT", "5432")),
        dbname=os.getenv("FP_DB_NAME", "freelancer_platform"),
        user=os.getenv("FP_DB_USER", "postgres"),
        password=password,
    )
