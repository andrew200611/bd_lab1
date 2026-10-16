-- ============================================================================
--  Крок 5 (п.5 завдання): ПОДАННЯ (VIEW)
--  Запуск:  psql -d freelancer_platform -f sql/05_views.sql
-- ----------------------------------------------------------------------------
--  Роль подань — подвійна:
--    1) приховати soft delete: код застосунку працює з активними даними,
--       не згадуючи is_deleted у кожному запиті;
--    2) зібрати розраховані показники (кількість, суми, залишок) в одному місці.
--
--  Саме ці подання викликає шар репозиторіїв на кроці 7 (п.7).
-- ============================================================================

SET search_path TO public;


-- ---------------------------------------------------------------------------
--  V1. Активні замовлення
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_active_project AS
SELECT p.p_uid,
       p.p_title,
       p.p_status,
       p.p_pricing_type,
       p.p_budget_min,
       p.p_budget_max,
       cur.cur_iso_code                 AS p_currency,
       cat.cat_name                     AS p_category,
       cp.cp_uid,
       cp.cp_company_name,
       u.u_email                        AS p_client,
       p.p_deadline,
       (SELECT count(*)
          FROM proposal pr
         WHERE pr.pr_p_uid = p.p_uid)   AS proposals_count,
       p.p_created_at
  FROM project p
  JOIN client_profile cp  ON cp.cp_uid   = p.p_cp_uid
  JOIN app_user       u   ON u.u_uid     = cp.cp_u_uid
  JOIN currency       cur ON cur.cur_uid = p.p_currency_uid
  LEFT JOIN category  cat ON cat.cat_uid = p.p_cat_uid
 WHERE p.p_is_deleted = false;

COMMENT ON VIEW v_active_project IS
    'Тільки невидалені замовлення + категорія, замовник, валюта, кількість відгуків';


-- ---------------------------------------------------------------------------
--  V2. Картка фрілансера
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_freelancer_card AS
SELECT fp.fp_uid,
       u.u_uid,
       u.u_email,
       fp.fp_title,
       fp.fp_hourly_rate,
       cur.cur_iso_code AS fp_currency,
       c.c_name         AS fp_country,
       fp.fp_rating_avg,
       fp.fp_is_available,
       (SELECT count(*) FROM freelancer_skill fs
         WHERE fs.fs_fp_uid = fp.fp_uid)  AS skills_count,
       (SELECT count(*) FROM contract ct
         WHERE ct.ct_fp_uid = fp.fp_uid)  AS contracts_count,
       fp.fp_created_at
  FROM freelancer_profile fp
  JOIN app_user u        ON u.u_uid     = fp.fp_u_uid
  LEFT JOIN currency cur ON cur.cur_uid = fp.fp_currency_uid
  LEFT JOIN country  c   ON c.c_uid     = fp.fp_country_uid
 WHERE u.u_is_deleted = false;

COMMENT ON VIEW v_freelancer_card IS
    'Картка фрілансера: контакт, ставка, рейтинг, кількість навичок і контрактів';


-- ---------------------------------------------------------------------------
--  V3. Фінанси контракту — ключовий звіт
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_contract_finance AS
SELECT ct.ct_uid,
       ct.ct_status,
       ct.ct_p_uid,
       uc.u_email       AS ct_client,
       uf.u_email       AS ct_freelancer,
       ct.ct_amount,
       cur.cur_iso_code AS ct_currency,
       (SELECT COALESCE(sum(ms.ms_amount), 0)
          FROM milestone ms
         WHERE ms.ms_ct_uid = ct.ct_uid)                        AS milestones_total,
       (SELECT COALESCE(sum(i.inv_amount), 0)
          FROM invoice i
         WHERE i.inv_ct_uid = ct.ct_uid
           AND i.inv_status <> 'CANCELLED')                     AS invoiced,
       fn_contract_paid(ct.ct_uid)                              AS paid,
       ct.ct_amount - fn_contract_paid(ct.ct_uid)               AS balance,
       ct.ct_start_date,
       ct.ct_end_date,
       ct.ct_updated_at
  FROM contract ct
  JOIN client_profile     cp  ON cp.cp_uid     = ct.ct_cp_uid
  JOIN freelancer_profile fp  ON fp.fp_uid     = ct.ct_fp_uid
  JOIN app_user           uc  ON uc.u_uid      = cp.cp_u_uid
  JOIN app_user           uf  ON uf.u_uid      = fp.fp_u_uid
  JOIN currency           cur ON cur.cur_uid   = ct.ct_currency_uid;

COMMENT ON VIEW v_contract_finance IS
    'Контракт очима бухгалтера: сума, виставлено рахунків, сплачено, залишок';


-- ---------------------------------------------------------------------------
--  V4. Дошка задач
-- ---------------------------------------------------------------------------
--  Задачі живуть під етапом, етап — під контрактом. Подання «піднімає» їх на
--  один рівень, щоб репозиторій задач не робив JOIN-ів самостійно.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_task_board AS
SELECT t.t_uid,
       t.t_ms_uid,
       ms.ms_title      AS ms_title,
       ms.ms_ct_uid,
       ct.ct_status     AS contract_status,
       t.t_title,
       t.t_status,
       t.t_hours_estimated,
       t.t_due_date,
       t.t_fp_uid,
       u.u_email        AS t_freelancer,
       (t.t_due_date IS NOT NULL
        AND t.t_due_date < current_date
        AND t.t_status <> 'DONE')  AS is_overdue,
       t.t_created_at,
       t.t_updated_at
  FROM task t
  JOIN milestone ms ON ms.ms_uid = t.t_ms_uid
  JOIN contract  ct ON ct.ct_uid = ms.ms_ct_uid
  LEFT JOIN freelancer_profile fp ON fp.fp_uid = t.t_fp_uid
  LEFT JOIN app_user           u  ON u.u_uid   = fp.fp_u_uid
 WHERE t.t_is_deleted = false;

COMMENT ON VIEW v_task_board IS
    'Невидалені задачі + етап, контракт, виконавець і ознака прострочення';


\echo '  -> 4 подання (View) створено'
