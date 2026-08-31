-- 0012 · Ledger core and immutability (WP-5)
--
-- BR-04: posted financial entries are never modified or deleted; corrections
-- are reversals. Migration 0007 created the tables and the per-line constraints
-- a column can express. This one adds the guarantees that need behaviour:
--
--   * an entry must balance, checked at commit rather than per statement
--   * an entry must have at least two lines
--   * a posted entry and its lines cannot be altered by anyone, owner included
--   * a locked accounting period accepts no postings
--   * a reversal is a mirrored entry linked to its original, and an entry can
--     be reversed exactly once
--
-- The balance check is deferred deliberately. A journal entry is written as an
-- entry and then its lines; an immediate check would fail on the first line of
-- every correct entry ever written. Deferring to commit is what lets the rule be
-- absolute instead of approximately enforced.

-- ===========================================================================
-- Balance
-- ===========================================================================
-- SECURITY DEFINER so the check sees every line of the entry. Under row-level
-- security a caller might see only some of them, and a balance check that
-- cannot see the whole entry is not a balance check.
create or replace function app.assert_entry_balanced()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_entry  uuid := coalesce(new.entry_id, old.entry_id);
    v_debit  numeric;
    v_credit numeric;
    v_lines  integer;
begin
    select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*)
      into v_debit, v_credit, v_lines
      from journal_line
     where entry_id = v_entry and deleted_at is null;

    -- The entry was removed entirely (only possible while rolling back a
    -- migration); nothing left to balance.
    if v_lines = 0 then
        return null;
    end if;

    if v_lines < 2 then
        raise exception 'journal entry % has only % line: an entry needs at least a debit and a credit',
            v_entry, v_lines
            using errcode = 'check_violation';
    end if;

    if v_debit <> v_credit then
        raise exception 'journal entry % does not balance: debits %, credits %, difference %',
            v_entry, v_debit, v_credit, v_debit - v_credit
            using errcode = 'check_violation',
                  hint = 'every entry must post equal debits and credits (BR-04)';
    end if;

    return null;
end $$;

comment on function app.assert_entry_balanced() is
    'Deferred balance check. An unbalanced ledger is not a preference, it is a broken ledger - so this is enforced by the database rather than by whoever wrote the posting code.';

drop trigger if exists zzz_journal_line_balanced on journal_line;
create constraint trigger zzz_journal_line_balanced
    after insert or update or delete on journal_line
    deferrable initially deferred
    for each row execute function app.assert_entry_balanced();

-- An entry with no lines at all would never reach the line trigger.
create or replace function app.assert_entry_has_lines()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_lines integer;
begin
    select count(*) into v_lines from journal_line
     where entry_id = new.id and deleted_at is null;
    if v_lines = 0 then
        raise exception 'journal entry % was posted with no lines', new.id
            using errcode = 'check_violation';
    end if;
    return null;
end $$;

drop trigger if exists zzz_journal_entry_has_lines on journal_entry;
create constraint trigger zzz_journal_entry_has_lines
    after insert on journal_entry
    deferrable initially deferred
    for each row execute function app.assert_entry_has_lines();

-- ===========================================================================
-- Immutability (BR-04)
-- ===========================================================================
-- Grants stop an application caller. This stops the owner too, so the guarantee
-- does not rest on nobody ever connecting as postgres. Undoing it means dropping
-- a trigger, which is a schema change and therefore reviewable.
create or replace function app.ledger_immutable()
returns trigger language plpgsql as $$
begin
    raise exception 'posted ledger rows cannot be % (BR-04)',
        case TG_OP when 'UPDATE' then 'modified' else 'deleted' end
        using errcode = 'insufficient_privilege',
              hint = 'correct a posting with app.reverse_journal_entry(), which leaves both entries visible';
end $$;

drop trigger if exists zzz_journal_entry_immutable on journal_entry;
create trigger zzz_journal_entry_immutable
    before update or delete on journal_entry
    for each row execute function app.ledger_immutable();

drop trigger if exists zzz_journal_line_immutable on journal_line;
create trigger zzz_journal_line_immutable
    before update or delete on journal_line
    for each row execute function app.ledger_immutable();

revoke update, delete on journal_entry from authenticated;
revoke update, delete on journal_line from authenticated;

-- ===========================================================================
-- Accounting periods
-- ===========================================================================
create or replace function app.assign_and_check_period()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_period_id uuid;
    v_status    text;
begin
    select p.id, p.status into v_period_id, v_status
      from accounting_period p
     where p.business_id = new.business_id
       and new.entry_date between p.starts_on and p.ends_on
       and p.deleted_at is null
     limit 1;

    -- No period defined for this date. Permitted: periods are created as the
    -- business needs them, and refusing to record a sale because a bookkeeping
    -- period has not been set up would stop the shop for an administrative
    -- reason. The entry is posted with a null period and picked up when the
    -- period is created.
    if v_period_id is null then
        return new;
    end if;

    if v_status = 'locked' then
        raise exception 'accounting period % is locked and accepts no postings', v_status
            using errcode = 'check_violation',
                  hint = 'post the correction into the current period instead';
    end if;

    new.period_id := coalesce(new.period_id, v_period_id);
    return new;
end $$;

comment on function app.assign_and_check_period() is
    'Resolves the period from the entry date and refuses a posting into a locked one. Corrections go to the current period as reversals (§4).';

drop trigger if exists a_journal_entry_period on journal_entry;
create trigger a_journal_entry_period
    before insert on journal_entry
    for each row execute function app.assign_and_check_period();

-- ===========================================================================
-- Posting and reversal
-- ===========================================================================
-- Posting an entry and its lines is one operation. Exposing it as a function
-- rather than leaving it to the caller means the balance rule is applied to
-- something whole, and gives the P3 domain services one place to build on.
create or replace function app.post_entry(
    p_business_id     uuid,
    p_branch_id       uuid,
    p_source_doc_type text,
    p_source_doc_id   uuid,
    p_memo            text,
    p_lines           jsonb,
    p_entry_date      date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_entry_id uuid := gen_random_uuid();
    v_line     jsonb;
    v_no       integer := 0;
begin
    -- An entry is written, then its lines. Both integrity checks must therefore
    -- be evaluated at the end, not between the two statements. Deferral is the
    -- default, but SET CONSTRAINTS is transaction-wide and sticky: any earlier
    -- statement in this transaction that made constraints immediate would break
    -- every subsequent posting. Declaring the requirement here means a correct
    -- posting cannot be broken by unrelated session state.
    set constraints all deferred;

    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
        raise exception 'an entry needs at least two lines'
            using errcode = 'check_violation';
    end if;

    insert into journal_entry (id, business_id, branch_id, entry_date,
                               source_doc_type, source_doc_id, memo)
    values (v_entry_id, p_business_id, p_branch_id, p_entry_date,
            p_source_doc_type, p_source_doc_id, p_memo);

    for v_line in select * from jsonb_array_elements(p_lines) loop
        v_no := v_no + 1;
        insert into journal_line (
            business_id, branch_id, entry_id, account_id, line_no,
            debit, credit, customer_id, supplier_id, garment_id, staff_id,
            stock_item_id, memo)
        values (
            p_business_id, p_branch_id, v_entry_id,
            (v_line ->> 'account_id')::uuid, v_no,
            coalesce((v_line ->> 'debit')::numeric, 0),
            coalesce((v_line ->> 'credit')::numeric, 0),
            (v_line ->> 'customer_id')::uuid,
            (v_line ->> 'supplier_id')::uuid,
            (v_line ->> 'garment_id')::uuid,
            (v_line ->> 'staff_id')::uuid,
            (v_line ->> 'stock_item_id')::uuid,
            v_line ->> 'memo');
    end loop;

    return v_entry_id;
end $$;

comment on function app.post_entry(uuid, uuid, text, uuid, text, jsonb, date) is
    'Posts an entry and its lines as one operation. The balance check fires at commit, so a caller cannot leave a half-written entry behind.';

-- An entry can be reversed exactly once. Without this, a retried request or a
-- double click produces two mirrored entries and the books drift by the amount
-- of the original.
create unique index journal_entry_one_reversal_per_original
    on journal_entry (reversal_of_id)
    where reversal_of_id is not null and deleted_at is null;

create or replace function app.reverse_journal_entry(
    p_entry_id     uuid,
    p_reason_code  text,
    p_reason_text  text default null,
    p_entry_date   date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_original journal_entry;
    v_new_id   uuid := gen_random_uuid();
begin
    -- Same reason as app.post_entry: the reversing entry is written before its
    -- mirrored lines.
    set constraints all deferred;

    select * into v_original from journal_entry where id = p_entry_id;
    if not found then
        raise exception 'journal entry % does not exist', p_entry_id
            using errcode = 'no_data_found';
    end if;

    if v_original.reversal_of_id is not null then
        raise exception 'entry % is itself a reversal and cannot be reversed', p_entry_id
            using errcode = 'check_violation',
                  hint = 'reverse the original entry, or post a fresh correcting entry';
    end if;

    if p_reason_code is null then
        raise exception 'a reversal must record why'
            using errcode = 'check_violation';
    end if;

    insert into journal_entry (id, business_id, branch_id, entry_date,
                               source_doc_type, source_doc_id, memo,
                               reversal_of_id, reversal_reason_code, reversal_reason_text)
    values (v_new_id, v_original.business_id, v_original.branch_id, p_entry_date,
            v_original.source_doc_type, v_original.source_doc_id,
            'Reversal of ' || coalesce(v_original.memo, p_entry_id::text),
            p_entry_id, p_reason_code, p_reason_text);

    -- Mirrored: every debit becomes a credit and every credit a debit, with the
    -- dimensions preserved so the reversal lands on the same customer, garment
    -- and branch as the original.
    insert into journal_line (business_id, branch_id, entry_id, account_id, line_no,
                              debit, credit, customer_id, supplier_id, garment_id,
                              staff_id, stock_item_id, memo)
    select l.business_id, l.branch_id, v_new_id, l.account_id, l.line_no,
           l.credit, l.debit, l.customer_id, l.supplier_id, l.garment_id,
           l.staff_id, l.stock_item_id, 'Reversal: ' || coalesce(l.memo, '')
      from journal_line l
     where l.entry_id = p_entry_id and l.deleted_at is null;

    return v_new_id;
end $$;

comment on function app.reverse_journal_entry(uuid, text, text, date) is
    'Creates the mirrored entry that cancels another. The original is untouched and both remain visible forever (BR-04).';

grant execute on function app.post_entry(uuid, uuid, text, uuid, text, jsonb, date) to authenticated, service_role;
grant execute on function app.reverse_journal_entry(uuid, text, text, date) to authenticated, service_role;

-- ===========================================================================
-- Trial balance
-- ===========================================================================
-- security_invoker is not optional here. A view runs with its owner's rights by
-- default, which would make it a hole straight through every row-level security
-- policy underneath it: any authenticated caller could read every business's
-- ledger through this view. With security_invoker the caller's own policies
-- apply. An assertion in the isolation suite checks that every view in the
-- schema sets it, so the next view cannot forget.
create view ledger_trial_balance with (security_invoker = true) as
select
    l.business_id,
    l.branch_id,
    l.account_id,
    a.code          as account_code,
    a.name          as account_name,
    a.account_type,
    sum(l.debit)    as debit_total,
    sum(l.credit)   as credit_total,
    sum(l.debit) - sum(l.credit) as net_movement
from journal_line l
join account a on a.id = l.account_id
where l.deleted_at is null
group by l.business_id, l.branch_id, l.account_id, a.code, a.name, a.account_type;

comment on view ledger_trial_balance is
    'Debits and credits per account per branch, derived from the ledger (AP-8). Runs with the caller''s privileges, so a user sees only their own business.';

grant select on ledger_trial_balance to authenticated, service_role;
