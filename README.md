# Інтернет-платформа для фрілансерів

Лабораторна робота з курсу баз даних. СУБД — PostgreSQL, мова — Python.

![ER-діаграма](diagram/er-diagram.png)

## Що всередині

- **`sql/`** — створення бази, 19 таблиць, демо-дані, 6 процедур, 4 подання,
  5 функцій, 7 тригерів, 5 індексів
- **`src/`** — шар доступу до даних (Repository + Unit of Work) і демонстрація

## Запуск

Потрібні PostgreSQL 18+ і Python 3.13+.

```
pip install -r requirements.txt
```

Створити базу (пароль береться зі змінної середовища, у коді його немає):

```
psql -U postgres -d postgres -f sql/01_create_database.sql
psql -U postgres -d freelancer_platform -f sql/02_schema.sql
psql -U postgres -d freelancer_platform -f sql/03_seed.sql
psql -U postgres -d freelancer_platform -f sql/04_functions.sql
psql -U postgres -d freelancer_platform -f sql/05_views.sql
psql -U postgres -d freelancer_platform -f sql/06_procedures.sql
psql -U postgres -d freelancer_platform -f sql/07_triggers.sql
psql -U postgres -d freelancer_platform -f sql/08_indexes.sql
```

Запустити демонстрацію:

```
FP_DB_PASSWORD=ВАШ_ПАРОЛЬ python src/demo_lifecycle.py
```

## Як це влаштовано

Застосунок не звертається до таблиць напряму: читає лише через подання
(`v_*`), змінює лише через збережені процедури (`sp_*`). Правило перевіряється
кодом (`src/freelancer/guards.py`), а не дисципліною.

Бізнес-правила живуть у базі: процедури тримають перевірки, тригери —
soft delete і аудит, подання — розрахунки.
