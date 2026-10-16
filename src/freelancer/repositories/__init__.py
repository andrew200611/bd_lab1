"""Репозиторії — по одному на групу сутностей.

Кожен репозиторій отримує спільне з'єднання від UnitOfWork, тому всі
вони працюють в одній транзакції. Самостійно відкрити з'єднання
репозиторій не може — і не повинен.
"""

from .base import BaseRepository
from .contract import ContractRepository
from .project import ProjectRepository
from .task import TaskRepository

__all__ = [
    "BaseRepository",
    "ProjectRepository",
    "ContractRepository",
    "TaskRepository",
]
