"""Спільна основа репозиторіїв.

КЛЮЧОВА ІДЕЯ ПАТЕРНА
    Репозиторій НЕ володіє з'єднанням — він його отримує ззовні, від
    Unit of Work. Саме тому кілька репозиторіїв працюють в ОДНІЙ транзакції:
    вони просто ділять один Connection. Якби кожен репозиторій відкривав
    своє з'єднання, «одна транзакція на кілька сутностей» була б неможлива.

ДВІ ЄДИНІ ДВЕРІ ДО БАЗИ
    _fetch*  — читання. Лише SELECT із подань v_*.
    _call    — зміни.   Лише CALL процедур sp_*.
    Обидва проходять через guards, тож обійти правило не вийде
    навіть випадково.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Any, Sequence, TypeVar

import psycopg
from psycopg import Connection
from psycopg.rows import class_row

from ..errors import translate
from ..guards import assert_procedure, assert_view_only

T = TypeVar("T")


def to_decimal(value: object) -> Decimal | None:
    """Приводить число до Decimal перед відправкою в процедуру.

    Навіщо це потрібно — довелося з'ясувати на власній помилці. psycopg
    відправляє Python float як `double precision`, а приведення
    `float8 -> numeric` у PostgreSQL НЕ є неявним. Через це виклик
    процедури з float-аргументом падає з «procedure does not exist»,
    хоча процедура існує.

    З цілим числом усе працювало випадково: `int2 -> numeric` — неявне
    приведення. Тобто код ламався лише на дробових сумах.

    Decimal передається як numeric напряму. Для грошей це взагалі
    єдиний коректний тип: float не здатен точно представити 0.1.
    """
    if value is None:
        return None
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


class BaseRepository:
    """Базовий клас для всіх репозиторіїв."""

    def __init__(self, conn: Connection, actor_uid: int) -> None:
        self._conn = conn
        self.actor_uid = actor_uid

    # ------------------------------------------------------------------ #
    #  Читання — лише подання
    # ------------------------------------------------------------------ #
    def _fetch(
        self,
        sql: str,
        params: Sequence[Any] = (),
        *,
        model: type[T] | None = None,
    ) -> list[T]:
        assert_view_only(sql)
        factory = class_row(model) if model is not None else None
        try:
            with self._conn.cursor(row_factory=factory) as cur:
                cur.execute(sql, params)
                return cur.fetchall()
        except psycopg.Error as exc:
            raise translate(exc, exc.sqlstate) from exc

    def _fetch_one(
        self,
        sql: str,
        params: Sequence[Any] = (),
        *,
        model: type[T] | None = None,
    ) -> T | None:
        rows = self._fetch(sql, params, model=model)
        return rows[0] if rows else None

    def _fetch_scalar(self, sql: str, params: Sequence[Any] = ()) -> Any:
        """SELECT, що повертає одне значення (count, sum тощо)."""
        assert_view_only(sql)
        try:
            with self._conn.cursor() as cur:
                cur.execute(sql, params)
                row = cur.fetchone()
                return row[0] if row else None
        except psycopg.Error as exc:
            raise translate(exc, exc.sqlstate) from exc

    # ------------------------------------------------------------------ #
    #  Зміни — лише процедури
    # ------------------------------------------------------------------ #
    def _call(self, procedure: str, args: Sequence[Any]) -> Any:
        """Викликає процедуру й повертає значення її OUT-параметра.

        Синтаксис CALL вимагає передати щось і на місце OUT-параметра —
        PostgreSQL не приймає «пропущене» значення. Передаємо NULL:
        сервер однаково поверне звідти результат.
        """
        assert_procedure(procedure)
        sql = f"CALL {procedure}({', '.join(['%s'] * (len(args) + 1))})"

        try:
            with self._conn.cursor() as cur:
                cur.execute(sql, (*args, None))
                row = cur.fetchone()
                return row[0] if row else None
        except psycopg.Error as exc:
            raise translate(exc, exc.sqlstate) from exc
