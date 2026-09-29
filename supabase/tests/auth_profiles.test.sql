-- B1: profile on signup, set_username, profiles write protection.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- Two users, as Supabase Auth would create them (email and an OAuth provider).
insert into auth.users (id, email, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.com', '{}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.com', '{"full_name":"Bee Tester","avatar_url":"https://example.com/b.png"}');

select is((select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-00000000000a'), 1,
  'signup creates exactly one profile');
select is((select display_name from public.profiles where id = '00000000-0000-0000-0000-00000000000b'), 'Bee Tester',
  'OAuth full_name copied to display_name');
select is((select username from public.profiles where id = '00000000-0000-0000-0000-00000000000a'), null,
  'username starts null');

-- Act as user A.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);

select lives_ok($$ select public.set_username('Alice_1') $$, 'set_username accepts a valid name');
select is((select username::text from public.profiles where id = '00000000-0000-0000-0000-00000000000a'), 'alice_1',
  'username stored lower-case');
select throws_ok($$ select public.set_username('ab') $$, 'P0001', 'INVALID_USERNAME', 'too short rejected');
select throws_ok($$ select public.set_username('bad name!') $$, 'P0001', 'INVALID_USERNAME', 'bad characters rejected');

-- Direct writes are refused for authenticated users.
select throws_ok($$ update public.profiles set storage_used = 0 where id = '00000000-0000-0000-0000-00000000000a' $$,
  '42501', null, 'authenticated cannot update profiles directly');
select throws_ok($$ insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000000ff') $$,
  '42501', null, 'authenticated cannot insert profiles');

-- User B cannot take A's name (case-insensitive).
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
select throws_ok($$ select public.set_username('ALICE_1') $$, 'P0001', 'USERNAME_TAKEN', 'duplicate name rejected');

-- Anonymous callers.
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$ select public.set_username('someone') $$, '42501', null, 'anon cannot call set_username');
select is((select count(*)::int from public.profiles), 2, 'anon can read public profiles');

select * from finish();
rollback;
