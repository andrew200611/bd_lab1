"""Демонстрація п.7: Repository + Unit of Work.

Запуск:
    FP_DB_PASSWORD=ВАШ_ПАРОЛЬ python src/demo_lifecycle.py

Що показуємо:
    СЦЕНАРІЙ 1 — повний життєвий цикл угоди (замовлення -> відгук ->
                 контракт -> етап -> рахунок -> платіж) у ОДНІЙ транзакції,
                 із COMMIT.
    СЦЕНАРІЙ 2 — доводимо, що відкат справді працює: усередині транзакції
                 кілька дій проходять успішно, потім одна падає, і НІЩО
                 не зберігається.
    СЦЕНАРІЙ 3 — доводимо, що обійти архітектурне правило не вийде:
                 спроба прочитати таблицю напряму падає з GuardViolation.
"""

from __future__ import annotations

import sys
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

# Щоб запускати як `python src/demo_lifecycle.py` без встановлення пакета.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from freelancer import (  # noqa: E402
    BusinessRuleViolation,
    GuardViolation,
    UnitOfWork,
    load_config,
)

# --------------------------------------------------------------------------
#  Ідентифікатори з демонстраційних даних (sql/03_seed.sql)
# --------------------------------------------------------------------------
CLIENT_PROFILE = 1      # Компанія 1
CLIENT_USER = 10
FREELANCER_PROFILE = 1  # Senior Full-Stack Developer
FREELANCER_USER = 20
CURRENCY_USD = 2

BUDGET = Decimal("3000.00")


def banner(text: str) -> None:
    print()
    print("=" * 74)
    print(f"  {text}")
    print("=" * 74)


def step(text: str) -> None:
    print(f"  {text}")


# ==========================================================================
#  СЦЕНАРІЙ 1. Повний життєвий цикл
# ==========================================================================
def scenario_full_lifecycle(cfg) -> None:
    banner("СЦЕНАРІЙ 1. Життєвий цикл угоди в одній транзакції")

    stamp = datetime.now().strftime("%Y%m%d%H%M%S")

    with UnitOfWork(cfg, actor_uid=CLIENT_USER) as uow:
        step("[замовник] публікує замовлення")
        p_uid = uow.projects.create(
            cp_uid=CLIENT_PROFILE,
            title=f"Демо-проєкт UoW від {datetime.now():%Y-%m-%d %H:%M:%S}",
            description="Потрібно написати серію технічних статей для документації.",
            pricing_type="FIXED",
            budget_min=BUDGET,
            budget_max=BUDGET,
            currency_uid=CURRENCY_USD,
            deadline=date.today() + timedelta(days=30),
            cat_uid=3,
        )
        step(f"            -> p_uid = {p_uid}")

        step("[фрілансер] подає відгук")
        uow.set_actor(FREELANCER_USER)
        pr_uid = uow.projects.submit_proposal(
            p_uid=p_uid,
            fp_uid=FREELANCER_PROFILE,
            cover_letter="Маю 8 років досвіду, робив 3 маркетплейси.",
            bid_amount=BUDGET,
            currency_uid=CURRENCY_USD,
            days=21,
        )
        step(f"            -> pr_uid = {pr_uid}")

        step("[замовник] приймає відгук — процедура робить 4 дії одразу")
        uow.set_actor(CLIENT_USER)
        ct_uid = uow.contracts.accept_proposal(
            pr_uid=pr_uid, start_date=date.today(), days=21
        )
        step(f"            -> ct_uid = {ct_uid}")

        step("[замовник] додає етапи")
        ms1 = uow.contracts.add_milestone(
            ct_uid=ct_uid, title="Етап 1: структура й перші статті",
            amount=Decimal("2000.00"), due_date=date.today() + timedelta(days=10),
        )
        ms2 = uow.contracts.add_milestone(
            ct_uid=ct_uid, title="Етап 2: фінальна вичитка",
            amount=Decimal("1000.00"), due_date=date.today() + timedelta(days=20),
        )
        step(f"            -> ms_uid = {ms1}, {ms2}")

        step("[замовник] виставляє рахунок і сплачує")
        inv_uid = uow.contracts.issue_invoice(
            ct_uid=ct_uid, number=f"INV-DEMO-{stamp}",
            amount=BUDGET, due_at=date.today() + timedelta(days=14),
        )
        pay_uid = uow.contracts.register_payment(
            inv_uid=inv_uid, amount=BUDGET, method="CARD",
            external_ref=f"DEMO-REF-{stamp}",
        )
        step(f"            -> inv_uid = {inv_uid}, pay_uid = {pay_uid}")

        # --- читання підсумку через ті самі репозиторії ---
        banner("ПІДСУМОК — читаємо назад через View")

        fin = uow.contracts.get(ct_uid)
        print(f"  Контракт {fin.ct_uid}: {fin.ct_status}, {fin.ct_amount} {fin.ct_currency}")
        print(f"    замовник    : {fin.ct_client}")
        print(f"    фрілансер   : {fin.ct_freelancer}")
        print(f"    етапи (сума): {fin.milestones_total}")
        print(f"    виставлено  : {fin.invoiced}")
        print(f"    сплачено    : {fin.paid}")
        print(f"    залишок     : {fin.balance}")

        print()
        print("  Прострочені задачі (ознаку is_overdue рахує подання, не Python):")
        for task in uow.tasks.overdue():
            print(f"    ! Задача {task.t_uid}: {task.t_title} "
                  f"(до {task.t_due_date}, {task.t_status})")

    print("\n  COMMIT — усе збережено.")


# ==========================================================================
#  СЦЕНАРІЙ 2. Доводимо, що відкат справді працює
# ==========================================================================
def scenario_rollback_proof(cfg) -> None:
    banner("СЦЕНАРІЙ 2. Збій усередині транзакції -> відкат УСЬОГО")

    with UnitOfWork(cfg, actor_uid=CLIENT_USER) as probe:
        before = probe.projects.count_active()
    print(f"  Активних замовлень ДО: {before}")

    error: Exception | None = None
    p_uid: int | None = None

    try:
        with UnitOfWork(cfg, actor_uid=CLIENT_USER) as uow:
            step("1) створюємо замовлення — успішно")
            p_uid = uow.projects.create(
                cp_uid=CLIENT_PROFILE,
                title="Проєкт, який мав би зникнути",
                description="Цей рядок не повинен залишитись у базі.",
                pricing_type="FIXED",
                budget_min=500, budget_max=500,
                currency_uid=CURRENCY_USD,
            )
            step(f"   -> p_uid = {p_uid}")

            step("2) подаємо відгук — теж успішно")
            pr_uid = uow.projects.submit_proposal(
                p_uid=p_uid, fp_uid=FREELANCER_PROFILE,
                cover_letter="Пробний відгук", bid_amount=500,
                currency_uid=CURRENCY_USD, days=5,
            )
            step(f"   -> pr_uid = {pr_uid}")

            step("3) тепер навмисно робимо неможливе: етап більший за контракт")
            uow.contracts.add_milestone(ct_uid=1, title="Завеликий", amount=999999)
            step("   !!! цього рядка не мало б бути видно — помилки не сталося")
    except BusinessRuleViolation as exc:
        error = exc
        step(f"4) очікувано впало: {exc}")

    print()
    print(f"  Перехоплено: {type(error).__name__}")

    with UnitOfWork(cfg, actor_uid=CLIENT_USER) as probe:
        after = probe.projects.count_active()
        vanished = probe.projects.get(p_uid) if p_uid else None

    print(f"  Активних замовлень ПІСЛЯ: {after}")
    print(f"  Замовлення p_uid={p_uid} у базі: {'ЗНАЙДЕНО — ДЕФЕКТ' if vanished else 'немає'}")
    if after == before and vanished is None:
        print("\n  ВИСНОВОК: обидві успішні дії відкотились разом із невдалою.")
    else:
        print("\n  ВИСНОВОК: відкат НЕ спрацював — це дефект.")


# ==========================================================================
#  СЦЕНАРІЙ 3. Правило п.7 перевіряється кодом
# ==========================================================================
def scenario_guard(cfg) -> None:
    banner("СЦЕНАРІЙ 3. Спробу обійти правило зупиняє стражник")

    with UnitOfWork(cfg, actor_uid=CLIENT_USER) as uow:
        for label, sql in (
            ("читання таблиці напряму", "SELECT p_uid, p_title FROM project"),
            ("спроба UPDATE",
             "SELECT 1 FROM v_active_project WHERE 1 = 1 -- UPDATE project SET p_title = 'x'"),
        ):
            try:
                uow.scalar(sql)
                step(f"  {label}: !!! пройшло — це дефект")
            except GuardViolation as exc:
                step(f"  {label} -> GuardViolation: {str(exc)[:80]}")

        try:
            uow.projects._call("fn_contract_paid", (1,))
            step("  виклик не-процедури: !!! пройшло — це дефект")
        except GuardViolation as exc:
            step(f"  виклик не-процедури -> GuardViolation: {str(exc)[:80]}")

    print("\n  ВИСНОВОК: порушити архітектурне правило з коду не вдається.")


# ==========================================================================
def main() -> int:
    cfg = load_config()
    print(f"Підключення: {cfg.user}@{cfg.host}:{cfg.port}/{cfg.dbname}")

    scenario_full_lifecycle(cfg)
    scenario_rollback_proof(cfg)
    scenario_guard(cfg)

    banner("ГОТОВО")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
