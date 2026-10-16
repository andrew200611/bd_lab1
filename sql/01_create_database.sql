-- ============================================================================
--  Крок 4 (п.4 завдання): створення бази даних
--  СУБД: PostgreSQL 18.6
-- ----------------------------------------------------------------------------
--  Запуск (підключившись до будь-якої БД, напр. postgres):
--      psql -U postgres -d postgres -f sql/01_create_database.sql
--
--  Кластер ініціалізовано з локалем Russian_Ukraine.1251, тому для нової БД
--  локаль задається явно: ICU-провайдер із локалем uk-UA — щоб сортування
--  українських назв було коректним, а не за кодовою сторінкою 1251.
-- ============================================================================

-- Якщо БД уже існує і її треба перестворити — розкоментувати:
-- DROP DATABASE IF EXISTS freelancer_platform WITH (FORCE);

CREATE DATABASE freelancer_platform
    WITH TEMPLATE        = template0
         ENCODING        = 'UTF8'
         LOCALE_PROVIDER = icu
         ICU_LOCALE      = 'uk-UA'
         LC_COLLATE      = 'C'
         LC_CTYPE        = 'C'
         CONNECTION LIMIT = -1;

COMMENT ON DATABASE freelancer_platform IS
    'Інтернет-платформа для фрілансерів — лабораторна робота з баз даних';

\echo '  -> базу freelancer_platform створено'
