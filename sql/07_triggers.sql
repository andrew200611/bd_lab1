-- ============================================================================
--  ТРИГЕРИ
--  Запуск:  psql -d freelancer_platform -f sql/07_triggers.sql
-- ----------------------------------------------------------------------------
--  Три функції-тригери закривають три різні задачі:
--
--    1) fn_set_audit_fields  — БУДЬ-ЯКА зміна рядка автоматично отримує
--       дату й автора зміни.
--       Страховка: навіть якщо хтось оновить рядок голим UPDATE з psql
--       і забуде про аудит — колонки все одно заповняться.
--
--    2) fn_soft_delete_instead — перехоплює фізичний DELETE і замінює його
--       на позначку is_deleted. Тобто soft delete неможливо «забути» —
--       його нав'язує сама база.
--
--    3) fn_block_payment_change — забороняє редагувати й видаляти платежі
--       (фінансовий регістр має бути незмінним).
--
--  Функції універсальні: щоб не писати по функції на кожну таблицю,
--  абревіатура передається аргументом тригера:
--      EXECUTE FUNCTION fn_set_audit_fields('p')
--  і назви колонок збираються з неї.
--
--  ВАЖЛИВО: TRUNCATE не викликає тригерів FOR EACH ROW, тому обходить
--  soft delete. Права на нього треба видавати окремо (REVOKE TRUNCATE).
-- ============================================================================

SET search_path TO public;


-- ===========================================================================
--  1. fn_set_audit_fields — проставити _updated_at / _updated_by
-- ===========================================================================
--  Чому через jsonb, а не через NEW.<колонка> = ... :
--  у BEFORE-тригері plpgsql можна змінювати NEW лише поіменно. Щоб зробити
--  це динамічно (ім'я колонки залежить від таблиці), перетворюємо рядок
--  у jsonb, правимо потрібні ключі й розгортаємо назад.
-- ===========================================================================
CREATE OR REPLACE FUNCTION fn_set_audit_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_abbr  text   := TG_ARGV[0];
    v_actor bigint := fn_current_app_user();
    v_new   jsonb;
BEGIN
    v_new := to_jsonb(NEW);
    v_new := jsonb_set(v_new, ARRAY[v_abbr || '_updated_at'], to_jsonb(now()), true);

    -- Якщо користувача в сесії не задано — не затираємо те, що вже є.
    IF v_actor IS NOT NULL THEN
        v_new := jsonb_set(v_new, ARRAY[v_abbr || '_updated_by'], to_jsonb(v_actor), true);
    END IF;

    NEW := jsonb_populate_record(NEW, v_new);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_set_audit_fields() IS
    'BEFORE UPDATE: проставляє <abbr>_updated_at = now() і <abbr>_updated_by зі змінної сесії';


-- ===========================================================================
--  2. fn_soft_delete_instead — DELETE перетворюється на soft delete
-- ===========================================================================
CREATE OR REPLACE FUNCTION fn_soft_delete_instead()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_abbr    text   := TG_ARGV[0];
    v_uid_col text   := v_abbr || '_uid';
    v_record  bigint;
BEGIN
    v_record := (to_jsonb(OLD) ->> v_uid_col)::bigint;

    EXECUTE format('UPDATE %I SET %I = true, %I = now() WHERE %I = $1',
                   TG_TABLE_NAME,
                   v_abbr || '_is_deleted',
                   v_abbr || '_deleted_at',
                   v_uid_col)
    USING v_record;

    RAISE NOTICE 'DELETE на % замінено на soft delete рядка %', TG_TABLE_NAME, v_record;

    RETURN NULL;   -- NULL скасовує фізичне видалення рядка
END;
$$;

COMMENT ON FUNCTION fn_soft_delete_instead() IS
    'BEFORE DELETE: замінює фізичне видалення на встановлення is_deleted / deleted_at';


-- ===========================================================================
--  3. fn_block_payment_change — платіж незмінний
-- ===========================================================================
CREATE OR REPLACE FUNCTION fn_block_payment_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Платіж pay_uid=% не можна % — фінансовий регістр незмінний',
                    OLD.pay_uid,
                    CASE TG_OP WHEN 'UPDATE' THEN 'редагувати' ELSE 'видаляти' END
          USING ERRCODE = 'check_violation';
END;
$$;

COMMENT ON FUNCTION fn_block_payment_change() IS
    'BEFORE UPDATE/DELETE на payment: забороняє будь-яку зміну вже збереженого платежу';


-- ===========================================================================
--  ПРИВ'ЯЗКА ТРИГЕРІВ
-- ===========================================================================
--  Аудит стоїть на транзакційних сутностях, soft delete — на тих, де фізичне
--  видалення ламає історію. Частина сутностей веде soft delete, частина —
--  дату останньої зміни й автора.
-- ===========================================================================

-- --- 1) Аудит: «коли» і «хто» оновив рядок --------------------------------
CREATE TRIGGER trg_auditfields_app_user BEFORE UPDATE ON app_user
    FOR EACH ROW EXECUTE FUNCTION fn_set_audit_fields('u');

CREATE TRIGGER trg_auditfields_project BEFORE UPDATE ON project
    FOR EACH ROW EXECUTE FUNCTION fn_set_audit_fields('p');

CREATE TRIGGER trg_auditfields_contract BEFORE UPDATE ON contract
    FOR EACH ROW EXECUTE FUNCTION fn_set_audit_fields('ct');

-- --- 2) Soft delete: DELETE -> UPDATE is_deleted --------------------------
CREATE TRIGGER trg_softdel_app_user BEFORE DELETE ON app_user
    FOR EACH ROW EXECUTE FUNCTION fn_soft_delete_instead('u');

CREATE TRIGGER trg_softdel_project BEFORE DELETE ON project
    FOR EACH ROW EXECUTE FUNCTION fn_soft_delete_instead('p');

CREATE TRIGGER trg_softdel_task BEFORE DELETE ON task
    FOR EACH ROW EXECUTE FUNCTION fn_soft_delete_instead('t');

-- --- 3) Незмінність платежів ---------------------------------------------
CREATE TRIGGER trg_payment_immutable BEFORE UPDATE OR DELETE ON payment
    FOR EACH ROW EXECUTE FUNCTION fn_block_payment_change();


\echo '  -> 3 функції-тригери і 7 тригерів створено'
