-- ============================================================================
--  ЗБЕРЕЖЕНІ ПРОЦЕДУРИ
--  Запуск:  psql -d freelancer_platform -f sql/06_procedures.sql
-- ----------------------------------------------------------------------------
--  Навіщо процедури, а не SQL із застосунку:
--    1) бізнес-правило живе в одному місці — його неможливо «забути» в коді;
--    2) застосунок не має прямого INSERT/UPDATE-доступу до таблиць:
--       будь-яка зміна проходить через процедуру;
--    3) перевірки виконуються всередині тієї ж транзакції, що й зміна.
--
--  Угоди:
--    * префікс sp_ — процедура (виклик CALL), fn_ — функція;
--    * останній параметр *_actor_uid — «хто виконує дію»; якщо NULL, беремо
--      зі змінної сесії app.current_user_uid (див. fn_current_app_user);
--    * результат повертаємо через OUT-параметр, а не через RAISE NOTICE —
--      так його зручно читати з клієнта (див. шар репозиторіїв).
--
--  ЧОМУ ПАРАМЕТРИ integer, А НЕ smallint ЯК У ТАБЛИЦЯХ:
--    PostgreSQL не має неявного приведення int4 → int2. Якби процедура
--    приймала smallint, то звичайний виклик CALL sp_...(..., 1, ...)
--    завершувався б помилкою «procedure does not exist» — і клієнту довелося
--    б писати 1::smallint. Тому на межі API приймаємо integer, а до типу
--    колонки приводимо вже всередині тіла.
-- ============================================================================

SET search_path TO public;


-- ===========================================================================
--  1. sp_create_project — опублікувати замовлення
-- ===========================================================================
CREATE OR REPLACE PROCEDURE sp_create_project(
    p_cp_uid       bigint,
    p_cat_uid      integer,
    p_title        varchar,
    p_description  text,
    p_pricing_type varchar,
    p_budget_min   numeric,
    p_budget_max   numeric,
    p_currency_uid integer,
    p_deadline     date,
    p_actor_uid    bigint,
    OUT o_p_uid    bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor bigint := COALESCE(p_actor_uid, fn_current_app_user());
BEGIN
    IF NOT EXISTS (SELECT 1 FROM client_profile WHERE cp_uid = p_cp_uid) THEN
        RAISE EXCEPTION 'Замовника cp_uid=% не знайдено', p_cp_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    IF p_cat_uid IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM category WHERE cat_uid = p_cat_uid
    ) THEN
        RAISE EXCEPTION 'Категорію cat_uid=% не знайдено', p_cat_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO project (p_cp_uid, p_cat_uid, p_title, p_description,
                         p_pricing_type, p_budget_min, p_budget_max,
                         p_currency_uid, p_status, p_deadline,
                         p_updated_at, p_updated_by)
    VALUES (p_cp_uid, p_cat_uid, p_title, p_description,
            p_pricing_type, p_budget_min, p_budget_max,
            p_currency_uid::smallint, 'OPEN', p_deadline,
            now(), v_actor)
    RETURNING p_uid INTO o_p_uid;
END;
$$;

COMMENT ON PROCEDURE sp_create_project(bigint, integer, varchar, text, varchar,
                                       numeric, numeric, integer, date, bigint, bigint) IS
    'Створює замовлення у статусі OPEN. Перевіряє замовника й категорію. Повертає p_uid';


-- ===========================================================================
--  2. sp_submit_proposal — фрілансер відгукується на замовлення
-- ===========================================================================
CREATE OR REPLACE PROCEDURE sp_submit_proposal(
    p_p_uid        bigint,
    p_fp_uid       bigint,
    p_cover_letter text,
    p_bid_amount   numeric,
    p_currency_uid integer,
    p_days         integer,
    p_actor_uid    bigint,
    OUT o_pr_uid   bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status varchar;
BEGIN
    SELECT p_status INTO v_status FROM project WHERE p_uid = p_p_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Замовлення p_uid=% не знайдено', p_p_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    IF v_status <> 'OPEN' THEN
        RAISE EXCEPTION 'Відгук можна подати лише на замовлення зі статусом OPEN (зараз %)', v_status
              USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM freelancer_profile WHERE fp_uid = p_fp_uid) THEN
        RAISE EXCEPTION 'Фрілансера fp_uid=% не знайдено', p_fp_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    -- UQ_proposal_pair не дасть подати два відгуки, але дамо зрозумілий текст.
    IF EXISTS (SELECT 1 FROM proposal
                WHERE pr_p_uid = p_p_uid AND pr_fp_uid = p_fp_uid) THEN
        RAISE EXCEPTION 'Фрілансер fp_uid=% уже подав відгук на замовлення p_uid=%',
                        p_fp_uid, p_p_uid
              USING ERRCODE = 'unique_violation';
    END IF;

    INSERT INTO proposal (pr_p_uid, pr_fp_uid, pr_cover_letter, pr_bid_amount,
                          pr_currency_uid, pr_days, pr_status)
    VALUES (p_p_uid, p_fp_uid, p_cover_letter, p_bid_amount,
            p_currency_uid::smallint, p_days::smallint, 'SENT')
    RETURNING pr_uid INTO o_pr_uid;
END;
$$;

COMMENT ON PROCEDURE sp_submit_proposal(bigint, bigint, text, numeric, integer,
                                        integer, bigint, bigint) IS
    'Подає відгук на відкрите замовлення. Повертає pr_uid';


-- ===========================================================================
--  3. sp_accept_proposal — прийняти відгук, народити контракт
-- ===========================================================================
--  Найцікавіша процедура: вона робить одразу чотири дії в одній транзакції —
--  приймає відгук, створює контракт, відхиляє конкурентні відгуки й переводить
--  замовлення в IN_PROGRESS. Якщо будь-що впаде — відкотиться все.
-- ===========================================================================
CREATE OR REPLACE PROCEDURE sp_accept_proposal(
    p_pr_uid     bigint,
    p_actor_uid  bigint,
    p_start_date date,
    p_days       integer,
    p_amount     numeric,        -- NULL → беремо суму з відгуку
    OUT o_ct_uid bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor  bigint := COALESCE(p_actor_uid, fn_current_app_user());
    v_pr     proposal%ROWTYPE;
    v_p      project%ROWTYPE;
    v_amount numeric;
    v_end    date;
BEGIN
    SELECT * INTO v_pr FROM proposal WHERE pr_uid = p_pr_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Відгук pr_uid=% не знайдено', p_pr_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    IF v_pr.pr_status IN ('ACCEPTED', 'REJECTED', 'WITHDRAWN') THEN
        RAISE EXCEPTION 'Відгук pr_uid=% уже закритий (статус %)', p_pr_uid, v_pr.pr_status
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_p FROM project WHERE p_uid = v_pr.pr_p_uid;

    IF EXISTS (SELECT 1 FROM contract WHERE ct_p_uid = v_p.p_uid) THEN
        RAISE EXCEPTION 'За замовленням p_uid=% уже укладено контракт', v_p.p_uid
              USING ERRCODE = 'unique_violation';
    END IF;

    v_amount := COALESCE(p_amount, v_pr.pr_bid_amount);
    v_end    := CASE WHEN p_days IS NULL THEN NULL ELSE p_start_date + p_days END;

    INSERT INTO contract (ct_pr_uid, ct_p_uid, ct_cp_uid, ct_fp_uid,
                          ct_amount, ct_currency_uid, ct_start_date, ct_end_date,
                          ct_status, ct_updated_at, ct_updated_by)
    VALUES (v_pr.pr_uid, v_p.p_uid, v_p.p_cp_uid, v_pr.pr_fp_uid,
            v_amount, v_pr.pr_currency_uid, p_start_date, v_end,
            'ACTIVE', now(), v_actor)
    RETURNING ct_uid INTO o_ct_uid;

    UPDATE proposal
       SET pr_status = 'ACCEPTED'
     WHERE pr_uid = p_pr_uid;

    UPDATE proposal
       SET pr_status = 'REJECTED'
     WHERE pr_p_uid = v_p.p_uid
       AND pr_uid  <> p_pr_uid
       AND pr_status IN ('SENT', 'VIEWED');

    UPDATE project
       SET p_status = 'IN_PROGRESS', p_updated_at = now(), p_updated_by = v_actor
     WHERE p_uid = v_p.p_uid;
END;
$$;

COMMENT ON PROCEDURE sp_accept_proposal(bigint, bigint, date, integer, numeric, bigint) IS
    'Приймає відгук → створює контракт, відхиляє інші відгуки, ставить проєкт IN_PROGRESS. Повертає ct_uid';


-- ===========================================================================
--  4. sp_add_milestone — додати етап до контракту
-- ===========================================================================
CREATE OR REPLACE PROCEDURE sp_add_milestone(
    p_ct_uid     bigint,
    p_title      varchar,
    p_amount     numeric,
    p_due_date   date,
    p_actor_uid  bigint,
    OUT o_ms_uid bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ct      contract%ROWTYPE;
    v_already numeric;
BEGIN
    SELECT * INTO v_ct FROM contract WHERE ct_uid = p_ct_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Контракт ct_uid=% не знайдено', p_ct_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    IF v_ct.ct_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Етапи можна додавати лише до активного контракту (зараз %)', v_ct.ct_status
              USING ERRCODE = 'check_violation';
    END IF;

    -- Сума етапів не повинна перевищувати суму контракту.
    SELECT COALESCE(sum(ms_amount), 0) INTO v_already
      FROM milestone WHERE ms_ct_uid = p_ct_uid;

    IF v_already + p_amount > v_ct.ct_amount THEN
        RAISE EXCEPTION 'Етапи перевищать суму контракту: уже % + новий % > %',
                        v_already, p_amount, v_ct.ct_amount
              USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO milestone (ms_ct_uid, ms_title, ms_amount, ms_due_date, ms_status)
    VALUES (p_ct_uid, p_title, p_amount, p_due_date, 'PENDING')
    RETURNING ms_uid INTO o_ms_uid;
END;
$$;

COMMENT ON PROCEDURE sp_add_milestone(bigint, varchar, numeric, date, bigint, bigint) IS
    'Додає етап; стежить, щоб сума етапів не перевищила суму контракту';


-- ===========================================================================
--  5. sp_issue_invoice — виставити рахунок за контрактом
-- ===========================================================================
CREATE OR REPLACE PROCEDURE sp_issue_invoice(
    p_ct_uid     bigint,
    p_number     varchar,
    p_amount     numeric,
    p_due_at     date,
    p_actor_uid  bigint,
    OUT o_inv_uid bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ct     contract%ROWTYPE;
    v_issued numeric;
BEGIN
    SELECT * INTO v_ct FROM contract WHERE ct_uid = p_ct_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Контракт ct_uid=% не знайдено', p_ct_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    -- Рахунки не можуть у сумі перевищити суму контракту.
    SELECT COALESCE(sum(inv_amount), 0) INTO v_issued
      FROM invoice
     WHERE inv_ct_uid = p_ct_uid AND inv_status <> 'CANCELLED';

    IF v_issued + p_amount > v_ct.ct_amount THEN
        RAISE EXCEPTION 'Рахунки перевищать суму контракту: уже % + новий % > %',
                        v_issued, p_amount, v_ct.ct_amount
              USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO invoice (inv_ct_uid, inv_number, inv_amount, inv_currency_uid,
                         inv_due_at, inv_status)
    VALUES (p_ct_uid, p_number, p_amount, v_ct.ct_currency_uid,
            p_due_at, 'ISSUED')
    RETURNING inv_uid INTO o_inv_uid;
END;
$$;

COMMENT ON PROCEDURE sp_issue_invoice(bigint, varchar, numeric, date, bigint, bigint) IS
    'Виставляє рахунок; стежить, щоб сума рахунків не перевищила суму контракту';


-- ===========================================================================
--  6. sp_register_payment — зареєструвати платіж за рахунком
-- ===========================================================================
--  Таблиця payment — фінансовий регістр: її рядки не редагуються й не
--  видаляються (див. trg_payment_immutable у 07_triggers.sql).
-- ===========================================================================
CREATE OR REPLACE PROCEDURE sp_register_payment(
    p_inv_uid      bigint,
    p_amount       numeric,
    p_method       varchar,
    p_external_ref varchar,
    p_actor_uid    bigint,
    OUT o_pay_uid  bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_inv  invoice%ROWTYPE;
    v_paid numeric;
BEGIN
    SELECT * INTO v_inv FROM invoice WHERE inv_uid = p_inv_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Рахунок inv_uid=% не знайдено', p_inv_uid
              USING ERRCODE = 'no_data_found';
    END IF;

    IF v_inv.inv_status = 'CANCELLED' THEN
        RAISE EXCEPTION 'Рахунок inv_uid=% скасовано — платіж неможливий', p_inv_uid
              USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO payment (pay_inv_uid, pay_amount, pay_currency_uid,
                         pay_method, pay_status, pay_paid_at, pay_external_ref)
    VALUES (p_inv_uid, p_amount, v_inv.inv_currency_uid,
            p_method, 'COMPLETED', now(), p_external_ref)
    RETURNING pay_uid INTO o_pay_uid;

    -- Якщо зібрано повну суму — рахунок стає PAID.
    SELECT COALESCE(sum(pay_amount), 0) INTO v_paid
      FROM payment
     WHERE pay_inv_uid = p_inv_uid AND pay_status = 'COMPLETED';

    IF v_paid >= v_inv.inv_amount THEN
        UPDATE invoice SET inv_status = 'PAID' WHERE inv_uid = p_inv_uid;
    END IF;
END;
$$;

COMMENT ON PROCEDURE sp_register_payment(bigint, numeric, varchar, varchar, bigint, bigint) IS
    'Реєструє COMPLETED-платіж і автоматично закриває рахунок при повній оплаті';


\echo '  -> 6 процедур створено'
