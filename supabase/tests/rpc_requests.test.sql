-- B5–B7 (database side): submit, changes requested, resubmit, approve, reject, promote, notifications.
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.com', '{}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.com', '{}');
update public.profiles set username = 'alice' where id = '00000000-0000-0000-0000-00000000000a';
update public.profiles set username = 'bob'   where id = '00000000-0000-0000-0000-00000000000b';

-- A's public project with one main version; B has two copies of it.
insert into public.projects (id, owner_id, title, type, license) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'P', 'writing', 'cc_by');
insert into public.versions (id, project_id, author_id, file_paths, file_hashes) overriding system value values
  (1, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '{a}', array[sha256('a')]);
insert into public.main_history (project_id, version_id, promoted_by) values
  ('10000000-0000-0000-0000-000000000001', 1, '00000000-0000-0000-0000-00000000000a');
update public.projects set main_version_id = 1;
insert into public.copies (id, project_id, author_id, project_owner_id, base_version_id, head_version_id)
overriding system value values
  (1, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a', 1, 1),
  (2, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a', 1, 1);

create temp table t (k text primary key, v bigint);
grant all on t to authenticated, service_role;

set local role authenticated;
-- ===== B submits copy 1 =====
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select lives_ok($$ insert into t values ('r', public.submit_request(1, 'please')) $$, 'B submits a request');
select is((select state::text from public.copies where id = 1), 'in_review', 'copy goes in_review');
select throws_ok($$ select public.submit_request(1) $$, 'P0001', 'INVALID_STATE', 'cannot submit twice');
select throws_ok($$ select public.review_request((select v from t where k = 'r'), 'approve') $$, 'P0001', 'NOT_AUTHORIZED',
  'contributor cannot review own request');

-- Frozen while pending.
reset role; set local role service_role;
select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001',
  1, 1, 'x', '[]', '{a}', '[]') $$, 'P0001', 'COPY_FROZEN', 'cannot save while pending');

-- ===== A asks for changes =====
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select is((select count(*)::int from public.notifications where type = 'request_submitted'), 1, 'owner notified once of submit');
select lives_ok($$ select public.review_request((select v from t where k = 'r'), 'request_changes', 'fix it') $$, 'A asks for changes');
select throws_ok($$ select public.review_request((select v from t where k = 'r'), 'approve') $$, 'P0001', 'INVALID_STATE',
  'cannot decide a non-pending request');

-- ===== B edits and resubmits =====
reset role; set local role service_role;
select lives_ok($$ insert into t values ('v2', public.commit_version('00000000-0000-0000-0000-00000000000b',
  '10000000-0000-0000-0000-000000000001', 1, 1, 'fixed', '[]', '{a}', '[]')) $$, 'B saves during changes_requested');
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select is((select count(*)::int from public.notifications where type = 'request_changes_requested'), 1, 'B notified of changes');
select lives_ok($$ select public.resubmit_request((select v from t where k = 'r'), 'done') $$, 'B resubmits');
select is((select submitted_version_id from public.review_requests), (select v from t where k = 'v2'),
  'request now points at the new head');

-- ===== A approves =====
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select lives_ok($$ select public.review_request((select v from t where k = 'r'), 'approve') $$, 'A approves');
select is((select state::text from public.copies where id = 1), 'published', 'copy published');
select is((select count(*)::int from public.request_events), 4, 'four events: submitted, changes, resubmitted, approved');

-- ===== Reject path on copy 2 =====
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select lives_ok($$ insert into t values ('r2', public.submit_request(2)) $$, 'B submits copy 2');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select lives_ok($$ select public.review_request((select v from t where k = 'r2'), 'reject', 'no') $$, 'A rejects');
select is((select count(*)::int from public.copies where id = 2), 0, 'rejected copy is private again (owner can no longer see it)');

-- ===== Promote (F10) =====
select lives_ok($$ select public.promote_copy(1) $$, 'A promotes fresh copy 1');
select is((select main_version_id from public.projects), (select v from t where k = 'v2'), 'main now points at the copy head');
-- Copy 1 was based on version 1; main has moved, so a second promote is stale.
select throws_ok($$ select public.promote_copy(1) $$, 'P0001', 'STALE_COPY', 'stale copy needs acknowledgement');

-- ===== Notifications =====
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select lives_ok($$ select public.mark_notifications_read(array(select id from public.notifications)) $$, 'B marks all read');

select * from finish();
rollback;
