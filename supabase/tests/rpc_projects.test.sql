-- B3/B4 (database side): create/update project, commit_version, restore_version, make_copy.
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.com', '{}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.com', '{}'),
  ('00000000-0000-0000-0000-00000000000c', 'c@example.com', '{}');
update public.profiles set username = 'alice' where id = '00000000-0000-0000-0000-00000000000a';
update public.profiles set username = 'bob'   where id = '00000000-0000-0000-0000-00000000000b';
-- c has no username.

create temp table t (k text primary key, v text);
grant all on t to authenticated, service_role;

-- ===== A creates a project =====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select lives_ok($$ insert into t values ('p', public.create_project('Essay', 'desc', 'writing', 'public', 'cc_by')::text) $$,
  'owner creates a project');
select lives_ok($$ select public.update_project((select v::uuid from t where k = 'p'), p_title => 'Essay 2') $$,
  'owner updates metadata');
select is((select title from public.projects), 'Essay 2', 'title updated');
select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000a', (select v::uuid from t where k = 'p'),
                    null, null, 'x', '[]', '{}', '[]') $$, '42501', null, 'authenticated cannot call commit_version');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated"}', true);
select throws_ok($$ select public.create_project('x', null, 'code', 'public', 'mit') $$, 'P0001', 'USERNAME_REQUIRED',
  'no username → refused');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select throws_ok($$ select public.update_project((select v::uuid from t where k = 'p'), p_title => 'pwned') $$,
  'P0001', 'NOT_AUTHORIZED', 'non-owner cannot update project');
select throws_ok($$ select public.make_copy((select v::uuid from t where k = 'p')) $$, 'P0001', 'NO_MAIN_VERSION',
  'cannot copy before first save');

-- ===== Saves (server, service role) =====
reset role;
set local role service_role;
select lives_ok($$ insert into t values ('v1', public.commit_version('00000000-0000-0000-0000-00000000000a',
  (select v::uuid from t where k = 'p'), null, null, 'first',
  jsonb_build_array(jsonb_build_object('path', 'a.txt', 'hash', encode(sha256('A'), 'hex')),
                    jsonb_build_object('path', 'b.txt', 'hash', encode(sha256('B'), 'hex'))),
  '{}',
  jsonb_build_array(jsonb_build_object('hash', encode(sha256('A'), 'hex'), 'size', 100),
                    jsonb_build_object('hash', encode(sha256('B'), 'hex'), 'size', 50)))::text) $$,
  'first save');
select is((select storage_used from public.profiles where username = 'alice'), 150::bigint, 'quota charged for new blobs');

-- Second save changes one file: delta of 1 upsert, reuse of b.txt is free.
select lives_ok($$ insert into t values ('v2', public.commit_version('00000000-0000-0000-0000-00000000000a',
  (select v::uuid from t where k = 'p'), null, (select v::bigint from t where k = 'v1'), 'second',
  jsonb_build_array(jsonb_build_object('path', 'a.txt', 'hash', encode(sha256('A2'), 'hex'))),
  '{}', jsonb_build_array(jsonb_build_object('hash', encode(sha256('A2'), 'hex'), 'size', 10)))::text) $$,
  'delta save');
select is((select file_paths from public.versions where id = (select v::bigint from t where k = 'v2')),
  '{a.txt,b.txt}'::text[], 'manifest keeps unchanged files');
select is((select storage_used from public.profiles where username = 'alice'), 160::bigint, 'only the new blob is charged');

select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000a',
  (select v::uuid from t where k = 'p'), null, (select v::bigint from t where k = 'v1'), 'stale', '[]', '{}', '[]') $$,
  'P0001', 'STALE_PARENT', 'saving on an old parent → STALE_PARENT');
select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000a',
  (select v::uuid from t where k = 'p'), null, (select v::bigint from t where k = 'v2'), 'x',
  jsonb_build_array(jsonb_build_object('path', 'c.txt', 'hash', encode(sha256('elsewhere'), 'hex'))), '{}', '[]') $$,
  'P0001', 'HASH_NOT_VERIFIED', 'hash not in parent and not uploaded → refused (F6/F11)');
select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000a',
  (select v::uuid from t where k = 'p'), null, (select v::bigint from t where k = 'v2'), 'big',
  jsonb_build_array(jsonb_build_object('path', 'big.bin', 'hash', encode(sha256('big'), 'hex'))), '{}',
  jsonb_build_array(jsonb_build_object('hash', encode(sha256('big'), 'hex'), 'size', 600 * 1024 * 1024))) $$,
  'P0001', 'QUOTA_EXCEEDED', 'over quota → refused');
select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000b',
  (select v::uuid from t where k = 'p'), null, (select v::bigint from t where k = 'v2'), 'x', '[]', '{}', '[]') $$,
  'P0001', 'NOT_AUTHORIZED', 'non-owner cannot save on main');

-- ===== Restore (owner) =====
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select lives_ok($$ insert into t values ('v3', public.restore_version((select v::uuid from t where k = 'p'),
  (select v::bigint from t where k = 'v1'))::text) $$, 'restore v1');
select is((select file_hashes from public.versions where id = (select v::bigint from t where k = 'v3')),
          (select file_hashes from public.versions where id = (select v::bigint from t where k = 'v1')),
  'restored version has v1''s manifest');
select is((select count(*)::int from public.main_history), 3, 'main_history has 3 entries');

-- ===== Copies =====
select throws_ok($$ select public.make_copy((select v::uuid from t where k = 'p')) $$, 'P0001', 'OWN_PROJECT',
  'owner cannot copy own project');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select lives_ok($$ insert into t values ('c', public.make_copy((select v::uuid from t where k = 'p'))::text) $$,
  'B makes a copy');
reset role;
set local role service_role;
select lives_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000b',
  (select v::uuid from t where k = 'p'), (select v::bigint from t where k = 'c'), (select v::bigint from t where k = 'v3'),
  'edit', '[]', '{b.txt}', '[]') $$, 'B saves on own copy (delete b.txt)');
select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000a',
  (select v::uuid from t where k = 'p'), (select v::bigint from t where k = 'c'), (select v::bigint from t where k = 'v3'),
  'x', '[]', '{}', '[]') $$, 'P0001', 'NOT_AUTHORIZED', 'owner cannot save on B''s copy');
reset role;
update public.copies set state = 'published', published_at = now();
set local role service_role;
select throws_ok($$ select public.commit_version('00000000-0000-0000-0000-00000000000b',
  (select v::uuid from t where k = 'p'), (select v::bigint from t where k = 'c'),
  (select head_version_id from public.copies), 'x', '[]', '{}', '[]') $$, 'P0001', 'COPY_FROZEN',
  'published copy is frozen');

select * from finish();
rollback;
