-- Row level security (BACKEND_PLAN.md §7). SELECT policies only: all writes go through RPCs (§6).

alter table public.profiles        enable row level security;
alter table public.projects        enable row level security;
alter table public.copies          enable row level security;
alter table public.versions        enable row level security;
alter table public.blobs           enable row level security;
alter table public.review_requests enable row level security;
alter table public.request_events  enable row level security;
alter table public.main_history    enable row level security;
alter table public.notifications   enable row level security;

revoke insert, update, delete, truncate
  on public.profiles, public.projects, public.copies, public.versions, public.blobs,
     public.review_requests, public.request_events, public.main_history, public.notifications
  from anon, authenticated;
-- blobs are reached only through server actions and read functions.
revoke select on public.blobs from anon, authenticated;
-- Tables added by later migrations must not inherit client write grants either.
alter default privileges in schema public
  revoke insert, update, delete, truncate on tables from anon, authenticated;

-- Helpers are STABLE SECURITY DEFINER so a policy on one table does not re-run another table's RLS.
create function public.is_project_readable(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.projects p
    where p.id = p_project_id
      and (p.visibility = 'public' or p.owner_id = (select auth.uid()))
  );
$$;

create function public.is_copy_readable(p_copy_id bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.copies c
    where c.id = p_copy_id
      and (c.author_id = (select auth.uid())
           or (c.state = 'in_review' and c.project_owner_id = (select auth.uid()))
           or (c.state = 'published' and public.is_project_readable(c.project_id)))
  );
$$;

revoke execute on function public.is_project_readable(uuid) from public;
revoke execute on function public.is_copy_readable(bigint) from public;
grant execute on function public.is_project_readable(uuid) to anon, authenticated;
grant execute on function public.is_copy_readable(bigint) to anon, authenticated;

create policy profiles_select on public.profiles
  for select to anon, authenticated
  using (true);

create policy projects_select on public.projects
  for select to anon, authenticated
  using (visibility = 'public' or owner_id = (select auth.uid()));

create policy copies_select on public.copies
  for select to anon, authenticated
  using (author_id = (select auth.uid())
         or (state = 'in_review' and project_owner_id = (select auth.uid()))
         or (state = 'published' and public.is_project_readable(project_id)));

create policy versions_select on public.versions
  for select to anon, authenticated
  using ((copy_id is null and public.is_project_readable(project_id))
         or (copy_id is not null and public.is_copy_readable(copy_id)));

create policy blobs_select on public.blobs
  for select to anon, authenticated
  using (false);

create policy review_requests_select on public.review_requests
  for select to authenticated
  using (owner_id = (select auth.uid()) or contributor_id = (select auth.uid()));

create policy request_events_select on public.request_events
  for select to authenticated
  using (exists (select 1 from public.review_requests r
                 where r.id = request_id
                   and (r.owner_id = (select auth.uid()) or r.contributor_id = (select auth.uid()))));

create policy main_history_select on public.main_history
  for select to anon, authenticated
  using (public.is_project_readable(project_id));

create policy notifications_select on public.notifications
  for select to authenticated
  using (user_id = (select auth.uid()));

-- Private Broadcast channel user:<uid> (E7): a user receives only their own channel.
create policy user_channel_receive on realtime.messages
  for select to authenticated
  using (realtime.messages.extension = 'broadcast'
         and (select realtime.topic()) = 'user:' || (select auth.uid())::text);
