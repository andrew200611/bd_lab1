"""Реалізація патернів Repository і Unit of Work.

ПРОБЛЕМА, ЯКУ ВИРІШУЄ UNIT OF WORK
    Бізнес-операція «прийняти відгук» зачіпає чотири таблиці. Якщо кожен
    репозиторій відкриватиме власне з'єднання й комітитиме сам, то збій
    посередині лишить базу в напівзруйнованому стані: контракт створено,
    а замовлення ще OPEN. Unit of Work тримає одне з'єднання й одну
    транзакцію на всю операцію — або все, або нічого.

РОЛЬ КОЖНОГО РЕПОЗИТОРІЮ
    Репозиторій знає, ЯК дістатися своєї сутності (яке подання читати,
    яку процедуру викликати). Він не знає нічого про транзакції, про
    з'єднання і про те, що поруч працюють інші репозиторії.

РОЛЬ UNIT OF WORK
    Володіє з'єднанням і транзакцією, створює репозиторії та передає їм
    спільний Connection, а також проставляє в сесії app.current_user_uid,
    щоб тригери аудиту знали, хто саме змінив рядок.
"""

from __future__ import annotations

from types import TracebackType

import psycopg
from psycopg import Connection

from .config import DbConfig
from .errors import translate
from .repositories.contract import ContractRepository
from .repositories.project import ProjectRepository
from .repositories.task import TaskRepository


class UnitOfWork:
    """Одна транзакція на набір логічно пов'язаних сутностей.

    Використання::

        with UnitOfWork(cfg, actor_uid=10) as uow:
            p_uid  = uow.projects.create(...)
            pr_uid = uow.projects.submit_proposal(p_uid=p_uid, ...)
            ct_uid = uow.contracts.accept_proposal(pr_uid=pr_uid, ...)
            # вихід із блоку без винятку -> COMMIT

        # виняток усередині блоку -> ROLLBACK, назовні летить далі

    Уся робота — в ОДНІЙ транзакції, тому всі репозиторії бачать зміни
    одне одного, але нічого не бачать інші підключення, поки не станеться
    COMMIT.
    """

    def __init__(self, config: DbConfig, actor_uid: int) -> None:
        self._config = config
        self.actor_uid = actor_uid
        self._conn: Connection | None = None
        # Позначка, що транзакцію вже закрито: сценарій може сам викликати
        # rollback(), а потім __exit__ спробує commit().
        self._finalized = False

        # Репозиторії створюються в __enter__, коли з'єднання вже є.
        self.projects: ProjectRepository
        self.contracts: ContractRepository
        self.tasks: TaskRepository

    # ------------------------------------------------------------------ #
    #  Керування транзакцією
    # ------------------------------------------------------------------ #
    def __enter__(self) -> "UnitOfWork":
        self._conn = psycopg.connect(self._config.dsn(), autocommit=False)
        self._finalized = False

        # SET LOCAL не приймає параметрів, тому використовуємо set_config
        # з is_local = true: значення діє до кінця транзакції.
        self._apply_actor()

        self.projects = ProjectRepository(self._conn, self.actor_uid)
        self.contracts = ContractRepository(self._conn, self.actor_uid)
        self.tasks = TaskRepository(self._conn, self.actor_uid)
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> bool:
        try:
            if exc_type is None:
                self.commit()
            else:
                self.rollback()
        finally:
            self.close()
        return False  # виняток не ковтаємо — нехай іде далі

    def commit(self) -> None:
        if not self._finalized and self._conn is not None and not self._conn.closed:
            self._conn.commit()
        self._finalized = True

    def rollback(self) -> None:
        if not self._finalized and self._conn is not None and not self._conn.closed:
            self._conn.rollback()
        self._finalized = True

    def close(self) -> None:
        if self._conn is not None and not self._conn.closed:
            self._conn.close()

    # ------------------------------------------------------------------ #
    #  Службове
    # ------------------------------------------------------------------ #
    def set_actor(self, actor_uid: int) -> None:
        """Змінює дійову особу, не розриваючи транзакцію.

        У реальній системі кожен запит користувача — це окремий UnitOfWork.
        Але буває, що одна операція виконується від імені різних сторін.
        Тоді актора треба перемкнути в межах транзакції — інакше тригери
        аудиту запишуть не того, хто насправді діяв.
        """
        self.actor_uid = actor_uid
        self._apply_actor()
        for repo in (self.projects, self.contracts, self.tasks):
            repo.actor_uid = actor_uid

    def scalar(self, sql: str, params: tuple = ()) -> object:
        """Службовий SELECT (для перевірок у демо-сценарії).

        Іде через той самий стражник, тому прочитати таблицю напряму
        не вийде навіть тут.
        """
        from .guards import assert_view_only

        assert_view_only(sql)
        conn = self._require_conn()
        try:
            with conn.cursor() as cur:
                cur.execute(sql, params)
                row = cur.fetchone()
                return row[0] if row else None
        except psycopg.Error as exc:
            raise translate(exc, exc.sqlstate) from exc

    def _apply_actor(self) -> None:
        """Проставляє актора у змінну сесії поточної транзакції."""
        conn = self._require_conn()
        with conn.cursor() as cur:
            cur.execute(
                "SELECT set_config('app.current_user_uid', %s, true)",
                (str(self.actor_uid),),
            )

    def _require_conn(self) -> Connection:
        if self._conn is None or self._conn.closed:
            raise RuntimeError(
                "UnitOfWork не активний. Використовуйте його як контекстний менеджер: "
                "with UnitOfWork(cfg, actor_uid) as uow: ..."
            )
        return self._conn
