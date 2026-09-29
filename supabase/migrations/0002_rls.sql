-- Row level security (BACKEND_PLAN.md §7). SELECT policies only: all writes go through RPCs.
-- B1 covers profiles; B2 adds the remaining tables and helpers.

alter table public.profiles enable row level security;

revoke insert, update, delete, truncate on public.profiles from anon, authenticated;

create policy profiles_select on public.profiles
  for select to anon, authenticated
  using (true);
