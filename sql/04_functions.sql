-- ============================================================================
--  КОРИСТУВАЦЬКІ ФУНКЦІЇ
--  Запуск:  psql -d freelancer_platform -f sql/04_functions.sql
-- ----------------------------------------------------------------------------
--  Тут — лише дві прикладні функції. Функції-тригери лежать окремо,
--  у 07_triggers.sql, щоб не змішувати різні механізми.
--
--  Угода про мову тіла функції:
--    LANGUAGE sql      — коли тіло є одним запитом (простіше й швидше);
--    LANGUAGE plpgsql  — коли потрібна логіка, змінні, винятки.
-- ============================================================================

SET search_path TO public;


-- ---------------------------------------------------------------------------
--  1. Хто зараз працює з базою
-- ---------------------------------------------------------------------------
--  uid користувача кладуть у змінну сесії:
--      SET LOCAL app.current_user_uid = '10';
--  Тригер аудиту читає її звідси. Якщо змінна не встановлена або вказує на
--  неіснуючого користувача — повертаємо NULL, щоб не зірвати операцію
--  через обмеження зовнішнього ключа.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_current_app_user()
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_raw text;
    v_uid bigint;
BEGIN
    v_raw := current_setting('app.current_user_uid', true);

    IF v_raw IS NULL OR btrim(v_raw) = '' THEN
        RETURN NULL;
    END IF;

    BEGIN
        v_uid := v_raw::bigint;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE WARNING 'app.current_user_uid = "%" не є числом — ігнорую', v_raw;
        RETURN NULL;
    END;

    IF NOT EXISTS (SELECT 1 FROM app_user WHERE u_uid = v_uid) THEN
        RAISE WARNING 'Користувача з uid=% не існує — ігнорую', v_uid;
        RETURN NULL;
    END IF;

    RETURN v_uid;
END;
$$;

COMMENT ON FUNCTION fn_current_app_user() IS
    'uid поточного користувача зі змінної сесії app.current_user_uid (NULL, якщо не задано)';


-- ---------------------------------------------------------------------------
--  2. Скільки грошей реально отримано за контрактом
-- ---------------------------------------------------------------------------
--  Рахуємо лише COMPLETED-платежі за нескасованими рахунками: платіж у стані
--  PENDING або FAILED грошима ще не став. Функція STABLE, бо читає таблиці,
--  але нічого не змінює.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_contract_paid(p_ct_uid bigint)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(sum(p.pay_amount), 0)
      FROM invoice i
      JOIN payment p ON p.pay_inv_uid = i.inv_uid
     WHERE i.inv_ct_uid  = p_ct_uid
       AND i.inv_status <> 'CANCELLED'
       AND p.pay_status  = 'COMPLETED';
$$;

COMMENT ON FUNCTION fn_contract_paid(bigint) IS
    'Фактично отримані гроші за контрактом: лише COMPLETED-платежі за нескасованими рахунками';


\echo '  -> 2 функції створено'
