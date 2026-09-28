-- Profile on signup + set_username (BACKEND_PLAN.md §4.1, §6).

-- One profile per auth.users row. Providers that share a verified email are linked to the same
-- auth user by Supabase Auth, so each person gets exactly one profile.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'), 100),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Sets (or changes) the caller's username. Errors: NOT_AUTHENTICATED, INVALID_USERNAME, USERNAME_TAKEN.
create function public.set_username(p_username text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := lower(trim(p_username));
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;
  if v_name is null or v_name !~ '^[a-z0-9_]{3,30}$' then
    raise exception 'INVALID_USERNAME' using errcode = 'P0001';
  end if;

  update public.profiles set username = v_name where id = v_uid;
  if not found then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;
exception
  when unique_violation then
    raise exception 'USERNAME_TAKEN' using errcode = 'P0001';
end;
$$;

revoke execute on function public.set_username(text) from public, anon;
grant execute on function public.set_username(text) to authenticated;
