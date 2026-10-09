-- B2: schema + RLS. User B cannot write any table, cannot update A's project,
-- and cannot read A's private project or someone else's private copy.
begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

-- Seed as postgres (RLS bypassed): A owns a public and a private project; B has a private copy of the public one.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.com', '{}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.com', '{}');

insert into public.projects (id, owner_id, title, type, visibility, license) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'Public', 'writing', 'public', 'cc_by'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'Secret', 'code', 'private', 'mit');

insert into public.versions (id, project_id, author_id, file_paths, file_hashes)
overriding system value values
  (1, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '{a.txt}', array[sha256('a')]),
  (2, '10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', '{s.txt}', array[sha256('s')]);
update public.projects set main_version_id = 1 where id = '10000000-0000-0000-0000-000000000001';
update public.projects set main_version_id = 2 where id = '10000000-0000-0000-0000-000000000002';

insert into public.copies (id, project_id, author_id, project_owner_id, base_version_id, head_version_id)
overriding system value values
  (1, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b',
   '00000000-0000-0000-0000-00000000000a', 1, 1);
insert into public.versions (id, project_id, copy_id, parent_id, author_id, file_paths, file_hashes)
overriding system value values
  (3, '10000000-0000-0000-0000-000000000001', 1, 1, '00000000-0000-0000-0000-00000000000b', '{a.txt}', array[sha256('b')]);
update public.copies set head_version_id = 3 where id = 1;

insert into public.blobs (hash, size, uploaded_by) values (sha256('a'), 1, '00000000-0000-0000-0000-00000000000a');
insert into public.notifications (user_id, type) values
  ('00000000-0000-0000-0000-00000000000a', 'test'), ('00000000-0000-0000-0000-00000000000b', 'test');

-- Schema constraints.
select throws_ok($$ insert into public.versions (project_id, author_id, file_paths, file_hashes)
                    values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '{x,y}', array[sha256('x')]) $$,
  '23514', null, 'manifest arrays must have equal length');
select throws_ok($$ insert into public.blobs (hash, size) values ('\x00'::bytea, 1) $$,
  '23514', null, 'blob hash must be 32 bytes');

-- ===== Act as B =====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);

select throws_ok($$ insert into public.projects (owner_id, title, type, license)
                    values ('00000000-0000-0000-0000-00000000000b', 'x', 'code', 'mit') $$,
  '42501', null, 'B cannot insert projects');
select throws_ok($$ update public.projects set title = 'pwned' where id = '10000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'B cannot update A''s project');
select throws_ok($$ update public.projects set main_version_id = 3 $$, '42501', null, 'B cannot move main pointer');
select throws_ok($$ delete from public.projects $$, '42501', null, 'B cannot delete projects');
select throws_ok($$ update public.copies set state = 'published', published_at = now() where id = 1 $$,
  '42501', null, 'B cannot publish own copy directly (F1)');
select throws_ok($$ insert into public.versions (project_id, author_id, file_paths, file_hashes)
                    values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', '{}', '{}') $$,
  '42501', null, 'B cannot insert versions');
select throws_ok($$ insert into public.blobs (hash, size) values (sha256('z'), 1) $$, '42501', null, 'B cannot insert blobs');
select throws_ok($$ insert into public.review_requests (copy_id, project_id, owner_id, contributor_id, submitted_version_id)
                    values (1, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a',
                            '00000000-0000-0000-0000-00000000000b', 3) $$,
  '42501', null, 'B cannot insert review_requests');
select throws_ok($$ insert into public.request_events (request_id, actor_id, kind)
                    values (1, '00000000-0000-0000-0000-00000000000b', 'approved') $$,
  '42501', null, 'B cannot insert request_events');
select throws_ok($$ insert into public.main_history (project_id, version_id, promoted_by)
                    values ('10000000-0000-0000-0000-000000000001', 3, '00000000-0000-0000-0000-00000000000b') $$,
  '42501', null, 'B cannot insert main_history');
select throws_ok($$ update public.notifications set read = true $$, '42501', null, 'B cannot update notifications directly');
select throws_ok($$ select * from public.blobs $$, '42501', null, 'B cannot read blobs');

select is((select count(*)::int from public.projects where id = '10000000-0000-0000-0000-000000000002'), 0,
  'B cannot read A''s private project');
select is((select count(*)::int from public.versions where id = 2), 0, 'B cannot read A''s private project versions');
select is((select count(*)::int from public.projects where id = '10000000-0000-0000-0000-000000000001'), 1,
  'B can read A''s public project');
select is((select count(*)::int from public.versions where id = 1), 1, 'B can read the public main line');
select is((select count(*)::int from public.versions where id = 3), 1, 'B can read own copy version');
select is((select count(*)::int from public.notifications), 1, 'B sees only own notifications');

-- ===== Act as A =====
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select is((select count(*)::int from public.copies where id = 1), 0, 'A cannot read B''s private copy');
select is((select count(*)::int from public.versions where id = 3), 0, 'A cannot read B''s private copy versions');
select is((select count(*)::int from public.projects), 2, 'A reads own public and private projects');

reset role;
update public.copies set state = 'in_review' where id = 1;
set local role authenticated;
select is((select count(*)::int from public.versions where id = 3), 1, 'A reads copy versions while in review');

-- ===== Anonymous =====
reset role;
update public.copies set state = 'published', published_at = now() where id = 1;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is((select count(*)::int from public.projects), 1, 'anon sees only public projects');
select is((select count(*)::int from public.versions where id = 3), 1, 'anon reads published copy versions');
select is((select count(*)::int from public.notifications), 0, 'anon sees no notifications');

select * from finish();
rollback;
