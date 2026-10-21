-- ============================================================================
--  Інтернет-платформа для фрілансерів
--  Файл 00: ПОВНЕ ОЧИЩЕННЯ БАЗИ (деструктивний — лише для розробки)
-- ----------------------------------------------------------------------------
--  Запуск:  psql -d freelancer_platform -f sql/00_drop_all.sql
--  УВАГА: видаляє всі дані проєкту.
--
--  Чому об'єкти логіки зносяться через цикл по системному каталогу, а не
--  списком імен: список довелося б синхронізувати руками після кожної
--  правки сигнатури, і він неминуче розійшовся б із реальністю. Тут ми
--  питаємо в самої бази, що в неї є, і зносимо це.
--
--  Порядок важливий: тригери -> подання -> процедури -> функції -> таблиці.
-- ============================================================================

SET client_min_messages = warning;
SET search_path TO public;


DO $$
DECLARE
    r record;
BEGIN
    -- ---- 1. Тригери (усі, крім внутрішніх, у схемі public) ----------------
    FOR r IN
        SELECT c.relname AS tbl, t.tgname AS trg
          FROM pg_trigger t
          JOIN pg_class     c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND NOT t.tgisinternal
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', r.trg, r.tbl);
        RAISE NOTICE '  drop trigger % on %', r.trg, r.tbl;
    END LOOP;

    -- ---- 2. Подання (View) -----------------------------------------------
    FOR r IN
        SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND c.relkind IN ('v', 'm')
    LOOP
        EXECUTE format('DROP VIEW IF EXISTS %I CASCADE', r.relname);
        RAISE NOTICE '  drop view %', r.relname;
    END LOOP;

    -- ---- 3. Процедури (prokind = 'p') ------------------------------------
    FOR r IN
        SELECT n.nspname, p.proname,
               pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.prokind = 'p'
    LOOP
        EXECUTE format('DROP PROCEDURE IF EXISTS %I.%I(%s) CASCADE',
                       r.nspname, r.proname, r.args);
        RAISE NOTICE '  drop procedure %.%(%)', r.nspname, r.proname, r.args;
    END LOOP;

    -- ---- 4. Функції (prokind = 'f'), включно з функціями-тригерами -------
    FOR r IN
        SELECT n.nspname, p.proname,
               pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.prokind = 'f'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.%I(%s) CASCADE',
                       r.nspname, r.proname, r.args);
        RAISE NOTICE '  drop function %.%(%)', r.nspname, r.proname, r.args;
    END LOOP;
END $$;


-- ---- 5. Таблиці (зворотний порядок до створення) --------------------------
DROP TABLE IF EXISTS review             CASCADE;
DROP TABLE IF EXISTS message            CASCADE;
DROP TABLE IF EXISTS chat_thread        CASCADE;
DROP TABLE IF EXISTS payment            CASCADE;
DROP TABLE IF EXISTS invoice            CASCADE;
DROP TABLE IF EXISTS task               CASCADE;
DROP TABLE IF EXISTS milestone          CASCADE;
DROP TABLE IF EXISTS contract           CASCADE;
DROP TABLE IF EXISTS proposal           CASCADE;
DROP TABLE IF EXISTS project            CASCADE;
DROP TABLE IF EXISTS freelancer_skill   CASCADE;
DROP TABLE IF EXISTS skill              CASCADE;
DROP TABLE IF EXISTS category           CASCADE;
DROP TABLE IF EXISTS freelancer_profile CASCADE;
DROP TABLE IF EXISTS client_profile     CASCADE;
DROP TABLE IF EXISTS currency           CASCADE;
DROP TABLE IF EXISTS country            CASCADE;
DROP TABLE IF EXISTS app_user           CASCADE;
DROP TABLE IF EXISTS role               CASCADE;


\echo '  -> усі об''єкти проєкту видалено'
