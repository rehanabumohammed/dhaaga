-- WP-5: the ledger's structural guarantees (BR-04).
--
-- Every assertion here runs as the table OWNER. Grants and policies do not
-- restrain an owner, so a pass proves the trigger is doing the work rather than
-- a privilege that a future migration could hand back.

insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111', 'Test Tailors');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main');
insert into customer (id, business_id, display_name)
values ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Imran Khan');
insert into account (id, business_id, code, name, account_type, normal_balance) values
 ('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '1100', 'Cash in hand',      'asset',     'debit'),
 ('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '2100', 'Customer advances', 'liability', 'credit'),
 ('a0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '4100', 'Sales - stitching', 'revenue',   'credit');

-- ---------------------------------------------------------------------------
-- A balanced entry posts
-- ---------------------------------------------------------------------------
-- Note on how these are written: the balance rule is a DEFERRED constraint
-- trigger, so it fires at commit, not at the offending statement. A test that
-- simply runs a statement and looks for an error would never see it - and, far
-- worse, a test that runs an unbalanced entry and asserts it "lives" would pass.
--
-- So every assertion below ends with `set constraints all immediate`, which
-- forces the deferred checks to run there and then. Without that line these
-- tests would be theatre.
--
-- The successful ones then set constraints back to deferred, because SET
-- CONSTRAINTS is transaction-wide and sticky - leaving it immediate would break
-- the next legitimate posting between its entry and its lines. Finding that is
-- what led app.post_entry() to declare its own deferral rather than trust the
-- session's.

select dhaaga_test.lives(
    $$select app.post_entry(
        '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'payment', null, 'Advance on ORD-0042',
        jsonb_build_array(
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000001', 'debit', 1500),
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000002', 'credit', 1500)));
      set constraints all immediate;
      set constraints all deferred$$,
    'a balanced entry posts, and survives the deferred balance check');

select dhaaga_test.eq(
    (select sum(debit) - sum(credit) from journal_line
     where business_id = '11111111-1111-1111-1111-111111111111'),
    0::numeric, 'and the ledger balances afterwards');

-- ---------------------------------------------------------------------------
-- An unbalanced entry does not
-- ---------------------------------------------------------------------------
-- The check is deferred to commit, so the failure surfaces when the enclosing
-- block ends rather than on the offending statement. That is the price of being
-- able to write an entry and its lines in the natural order.
select dhaaga_test.throws(
    $$select app.post_entry(
        '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'manual_adjustment', null, 'Does not balance',
        jsonb_build_array(
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000001', 'debit', 1000),
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000002', 'credit', 900)));
      set constraints all immediate$$,
    'an entry whose debits and credits differ is refused', '23514');

select dhaaga_test.throws(
    $$select app.post_entry(
        '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'manual_adjustment', null, 'One-sided',
        jsonb_build_array(
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000001', 'debit', 500)));
      set constraints all immediate$$,
    'a one-sided entry is refused', '23514');

-- Written by hand rather than through the helper, to prove the guarantee is in
-- the database and not in the convenience function.
select dhaaga_test.throws(
    $$insert into journal_entry (id, business_id, branch_id, source_doc_type, memo)
      values ('e0000000-0000-0000-0000-00000000dead', '11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222222', 'manual_adjustment', 'Hand-written, no lines');
      set constraints all immediate$$,
    'an entry posted with no lines at all is refused', '23514');

select dhaaga_test.throws(
    $$insert into journal_entry (id, business_id, branch_id, source_doc_type, memo)
      values ('e0000000-0000-0000-0000-00000000beef', '11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222222', 'manual_adjustment', 'Hand-written, unbalanced');
      insert into journal_line (business_id, branch_id, entry_id, account_id, debit)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'e0000000-0000-0000-0000-00000000beef', 'a0000000-0000-0000-0000-000000000001', 700);
      insert into journal_line (business_id, branch_id, entry_id, account_id, credit)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'e0000000-0000-0000-0000-00000000beef', 'a0000000-0000-0000-0000-000000000002', 650);
      set constraints all immediate$$,
    'and so is a hand-written unbalanced entry, bypassing the posting helper', '23514');

-- ---------------------------------------------------------------------------
-- A posted entry cannot be altered - by anyone
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$update journal_entry set memo = 'Rewritten history'
      where memo = 'Advance on ORD-0042'$$,
    'a posted entry cannot be modified, even by the table owner', '42501');

select dhaaga_test.throws(
    $$delete from journal_entry where memo = 'Advance on ORD-0042'$$,
    'nor deleted', '42501');

select dhaaga_test.throws(
    $$update journal_entry set deleted_at = now() where memo = 'Advance on ORD-0042'$$,
    'nor soft-deleted out of the reports', '42501');

select dhaaga_test.throws(
    $$update journal_line set debit = 999999
      where entry_id = (select id from journal_entry where memo = 'Advance on ORD-0042')$$,
    'and an individual line cannot be edited to change what an entry says', '42501');

select dhaaga_test.throws(
    $$delete from journal_line
      where entry_id = (select id from journal_entry where memo = 'Advance on ORD-0042')$$,
    'nor removed to unbalance it', '42501');

-- ---------------------------------------------------------------------------
-- Reversal is the only correction (BR-04)
-- ---------------------------------------------------------------------------
select dhaaga_test.lives(
    $$select app.reverse_journal_entry(
        (select id from journal_entry where memo = 'Advance on ORD-0042'),
        'entered_twice', 'Counter recorded the advance on two devices');
      set constraints all immediate;
      set constraints all deferred$$,
    'a reversal is accepted, and balances');

select dhaaga_test.eq(
    (select count(*)::int from journal_entry
     where business_id = '11111111-1111-1111-1111-111111111111'),
    2, 'the original entry survives alongside its reversal - nothing was erased');

select dhaaga_test.eq(
    (select sum(debit) + sum(credit) from journal_line
     where entry_id = (select id from journal_entry where reversal_of_id is not null)),
    3000::numeric, 'the reversal carries the same amounts');

select dhaaga_test.eq(
    (select sum(l.debit) - sum(l.credit) from journal_line l
     join account a on a.id = l.account_id
     where a.code = '1100' and l.business_id = '11111111-1111-1111-1111-111111111111'),
    0::numeric, 'and cancels the original exactly: the cash account nets to zero');

select dhaaga_test.eq(
    (select reversal_reason_code from journal_entry where reversal_of_id is not null),
    'entered_twice', 'with the reason recorded on the reversing entry');

select dhaaga_test.throws(
    $$select app.reverse_journal_entry(
        (select id from journal_entry where memo = 'Advance on ORD-0042'), 'entered_twice')$$,
    'an entry cannot be reversed twice - a retry or a double click must not double the correction', '23505');

select dhaaga_test.throws(
    $$select app.reverse_journal_entry(
        (select id from journal_entry where reversal_of_id is not null), 'oops')$$,
    'and a reversal cannot itself be reversed', '23514');

select dhaaga_test.throws(
    $$select app.reverse_journal_entry(
        (select id from journal_entry where memo = 'Advance on ORD-0042'), null)$$,
    'a reversal without a reason is refused', '23514');

-- ---------------------------------------------------------------------------
-- Locked periods
-- ---------------------------------------------------------------------------
insert into accounting_period (business_id, code, starts_on, ends_on, status, locked_at)
values ('11111111-1111-1111-1111-111111111111', '2026-07', '2026-07-01', '2026-07-31', 'locked', now());
insert into accounting_period (business_id, code, starts_on, ends_on, status)
values ('11111111-1111-1111-1111-111111111111', '2026-08', '2026-08-01', '2026-08-31', 'open');

select dhaaga_test.throws(
    $$select app.post_entry(
        '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'manual_adjustment', null, 'Backdated into a locked month',
        jsonb_build_array(
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000001', 'debit', 100),
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000003', 'credit', 100)),
        date '2026-07-15');
      set constraints all immediate$$,
    'a posting into a locked period is refused', '23514');

select dhaaga_test.lives(
    $$select app.post_entry(
        '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'manual_adjustment', null, 'Correction in the open month',
        jsonb_build_array(
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000001', 'debit', 100),
            jsonb_build_object('account_id', 'a0000000-0000-0000-0000-000000000003', 'credit', 100)),
        date '2026-08-15');
      set constraints all immediate;
      set constraints all deferred$$,
    'the same correction into the open period is accepted - which is how BR-04 corrections are meant to work');

select dhaaga_test.eq(
    (select p.code from journal_entry e join accounting_period p on p.id = e.period_id
     where e.memo = 'Correction in the open month'),
    '2026-08', 'and the entry is filed into the period its date falls in, without the caller saying so');

-- ---------------------------------------------------------------------------
-- The trial balance view, and the hole it could have been
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    (select sum(net_movement) from ledger_trial_balance
     where business_id = '11111111-1111-1111-1111-111111111111'),
    0::numeric, 'the trial balance nets to zero across every account');

-- Postgres stores this as security_invoker=true; matching on the substring
-- rather than an exact string keeps the assertion honest if that spelling ever
-- changes.
select dhaaga_test.ok(
    (select array_to_string(reloptions, ',') like '%security_invoker=true%'
     from pg_class where relname = 'ledger_trial_balance'),
    'the view runs with the caller''s privileges - without this it would read every business''s ledger straight through row-level security');
