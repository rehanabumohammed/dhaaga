-- Cluster 2.5 behaviour: the ledger's structural guarantees.
-- WP-5 adds the entry-level balance constraint and revokes UPDATE/DELETE on
-- posted rows; these are the guarantees a table definition can carry today.

insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111', 'Test Tailors');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main');
insert into app_user (id, business_id, full_name)
values ('77777777-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Counter staff');
insert into customer (id, business_id, display_name)
values ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Imran Khan');

insert into account (id, business_id, code, name, account_type, normal_balance) values
 ('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '1100', 'Cash in hand', 'asset', 'debit'),
 ('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '2100', 'Customer advances', 'liability', 'credit'),
 ('a0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '1200', 'Accounts receivable', 'asset', 'debit'),
 ('a0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', '4100', 'Sales - stitching', 'revenue', 'credit'),
 ('a0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', '4900', 'Discounts allowed', 'revenue', 'debit');

update account set is_contra = true where code = '4900' and business_id = '11111111-1111-1111-1111-111111111111';

select dhaaga_test.eq(
    (select normal_balance from account where code = '4900' and business_id = '11111111-1111-1111-1111-111111111111'), 'debit',
    'discounts allowed sits under revenue but increases on the debit side - contra-revenue, not an expense (BR-20)');

select dhaaga_test.throws(
    $$update account set parent_id = id where code = '1100' and business_id = '11111111-1111-1111-1111-111111111111'$$,
    'an account cannot be its own parent', '23514');

-- ---------------------------------------------------------------------------
-- Accounting periods cannot overlap
-- ---------------------------------------------------------------------------
insert into accounting_period (business_id, code, starts_on, ends_on)
values ('11111111-1111-1111-1111-111111111111', '2026-08', '2026-08-01', '2026-08-31');

select dhaaga_test.throws(
    $$insert into accounting_period (business_id, code, starts_on, ends_on)
      values ('11111111-1111-1111-1111-111111111111', '2026-08b', '2026-08-15', '2026-09-15')$$,
    'two accounting periods cannot cover the same day', '23P01');

select dhaaga_test.throws(
    $$insert into accounting_period (business_id, code, starts_on, ends_on, status)
      values ('11111111-1111-1111-1111-111111111111', '2026-09', '2026-09-01', '2026-09-30', 'locked')$$,
    'a period cannot be locked without recording when', '23514');

-- ---------------------------------------------------------------------------
-- Journal lines: a debit or a credit, never both, never neither
-- ---------------------------------------------------------------------------
insert into journal_entry (id, business_id, branch_id, source_doc_type, memo)
values ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'payment', 'Advance on ORD-0042');

insert into journal_line (business_id, branch_id, entry_id, account_id, debit, customer_id)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 1500.00,
        'cccccccc-0000-0000-0000-000000000001');
insert into journal_line (business_id, branch_id, entry_id, account_id, credit, customer_id)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 1500.00,
        'cccccccc-0000-0000-0000-000000000001');

select dhaaga_test.eq(
    (select sum(debit) - sum(credit) from journal_line where entry_id = 'e0000000-0000-0000-0000-000000000001'),
    0::numeric, 'the advance entry balances: cash up, liability up, no revenue (§4)');

select dhaaga_test.eq(
    (select sum(credit) from journal_line jl join account a on a.id = jl.account_id
     where a.account_type = 'revenue' and not a.is_contra and jl.business_id = '11111111-1111-1111-1111-111111111111'),
    null::numeric, 'taking an advance creates no revenue at all - BR-02, BR-03');

select dhaaga_test.throws(
    $$insert into journal_line (business_id, entry_id, account_id, debit, credit)
      values ('11111111-1111-1111-1111-111111111111', 'e0000000-0000-0000-0000-000000000001',
              'a0000000-0000-0000-0000-000000000001', 100, 100)$$,
    'a line cannot be both a debit and a credit', '23514');

select dhaaga_test.throws(
    $$insert into journal_line (business_id, entry_id, account_id)
      values ('11111111-1111-1111-1111-111111111111', 'e0000000-0000-0000-0000-000000000001',
              'a0000000-0000-0000-0000-000000000001')$$,
    'a line with neither a debit nor a credit is rejected', '23514');

select dhaaga_test.throws(
    $$insert into journal_line (business_id, entry_id, account_id, debit)
      values ('11111111-1111-1111-1111-111111111111', 'e0000000-0000-0000-0000-000000000001',
              'a0000000-0000-0000-0000-000000000001', -50)$$,
    'a negative amount is rejected - direction is expressed by the side, not the sign', '23514');

-- ---------------------------------------------------------------------------
-- Reversal, never edit (BR-04)
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$insert into journal_entry (business_id, branch_id, source_doc_type, reversal_of_id)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'payment', 'e0000000-0000-0000-0000-000000000001')$$,
    'a reversal without a recorded reason is refused', '23514');

select dhaaga_test.lives(
    $$insert into journal_entry (business_id, branch_id, source_doc_type, reversal_of_id, reversal_reason_code)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'payment', 'e0000000-0000-0000-0000-000000000001', 'entered_twice')$$,
    'a reversal with a reason is accepted, and both entries remain visible');

-- ---------------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------------
insert into payment_mode (id, business_id, code, label, account_id, is_cash)
values ('40000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'CASH', 'Cash', 'a0000000-0000-0000-0000-000000000001', true);

insert into cash_session (id, business_id, branch_id, user_id, opening_float)
values ('50000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', '77777777-0000-0000-0000-000000000001', 2000);

select dhaaga_test.throws(
    $$insert into cash_session (business_id, branch_id, user_id, opening_float)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '77777777-0000-0000-0000-000000000001', 500)$$,
    'one person cannot have two drawers open at one branch', '23505');

select dhaaga_test.throws(
    $$update cash_session set status = 'closed', closed_at = now()
      where id = '50000000-0000-0000-0000-000000000001'$$,
    'a drawer cannot be closed without a counted amount', '23514');

insert into payment (id, business_id, branch_id, direction, customer_id, amount, mode_id, cash_session_id)
values ('60000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'in', 'cccccccc-0000-0000-0000-000000000001',
        1500, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001');

select dhaaga_test.throws(
    $$insert into payment (business_id, branch_id, direction, amount, mode_id)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'in', 500, '40000000-0000-0000-0000-000000000001')$$,
    'a payment attached to nobody cannot be reconciled and is rejected', '23514');

select dhaaga_test.throws(
    $$insert into payment (business_id, branch_id, direction, customer_id, amount, mode_id)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'in', 'cccccccc-0000-0000-0000-000000000001', 0, '40000000-0000-0000-0000-000000000001')$$,
    'a payment of zero is not a payment', '23514');

select dhaaga_test.throws(
    $$insert into payment (business_id, branch_id, direction, customer_id, amount, mode_id, reversal_of_id)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'in', 'cccccccc-0000-0000-0000-000000000001', 1500,
              '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001')$$,
    'reversing a payment without a reason is refused', '23514');

-- An allocation settles exactly one kind of debt.
select dhaaga_test.throws(
    $$insert into payment_allocation (business_id, payment_id, amount)
      values ('11111111-1111-1111-1111-111111111111', '60000000-0000-0000-0000-000000000001', 500)$$,
    'an allocation must name what it settles', '23514');

-- ---------------------------------------------------------------------------
-- Wages (BR-16)
-- ---------------------------------------------------------------------------
insert into wage_scheme (business_id, user_id, scheme_type, effective_from)
values ('11111111-1111-1111-1111-111111111111', '77777777-0000-0000-0000-000000000001', 'piece_rate', '2026-01-01');

select dhaaga_test.throws(
    $$insert into wage_scheme (business_id, user_id, scheme_type, effective_from)
      values ('11111111-1111-1111-1111-111111111111', '77777777-0000-0000-0000-000000000001', 'salary', '2026-06-01')$$,
    'one person cannot be on two wage schemes at once', '23P01');

select dhaaga_test.throws(
    $$insert into wage_entry (business_id, branch_id, user_id, amount, kind)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '77777777-0000-0000-0000-000000000001', -200, 'piece_rate')$$,
    'piece-rate earnings cannot be negative - a deduction is an adjustment with a reason', '23514');

select dhaaga_test.lives(
    $$insert into wage_entry (business_id, branch_id, user_id, amount, kind, reason_code)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '77777777-0000-0000-0000-000000000001', -200, 'penalty', 'damaged_fabric')$$,
    'a penalty is recorded as its own entry with a reason, never as an edit to what was earned');

insert into staff_advance (business_id, branch_id, user_id, amount, recovered_amount)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '77777777-0000-0000-0000-000000000001', 5000, 2000);

select dhaaga_test.throws(
    $$update staff_advance set recovered_amount = 6000
      where user_id = '77777777-0000-0000-0000-000000000001' and business_id = '11111111-1111-1111-1111-111111111111'$$,
    'an advance cannot be over-recovered', '23514');

select dhaaga_test.throws(
    $$insert into wage_payout (business_id, branch_id, user_id, period_start, period_end, status)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '77777777-0000-0000-0000-000000000001', '2026-08-01', '2026-08-07', 'locked')$$,
    'a payout cannot be locked without recording when', '23514');
