-- Write RPCs (BACKEND_PLAN.md §6). SECURITY DEFINER, empty search_path, actor checked first, one transaction each.
-- This file covers projects, saves and copies. Requests, promote and notifications follow in B5–B7.
-- Errors are raised as P0001 with a stable code in the message (NOT_AUTHENTICATED, NOT_AUTHORIZED, ...).

-- Caller must be signed in and have picked a username. Returns the uid.
create function public.require_actor(p_uid uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where id = p_uid and username is not null) then
    raise exception 'USERNAME_REQUIRED' using errcode = 'P0001';
  end if;
  return p_uid;
end;
$$;
revoke execute on function public.require_actor(uuid) from public, anon, authenticated;

create function public.create_project(
  p_title text, p_description text, p_type public.project_type,
  p_visibility public.visibility, p_license public.license_type)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
  v_id uuid;
begin
  insert into public.projects (owner_id, title, description, type, visibility, license)
  values (v_uid, trim(p_title), nullif(trim(p_description), ''), p_type, p_visibility, p_license)
  returning id into v_id;
  return v_id;
end;
$$;

-- Null arguments leave the field unchanged. main_version_id is never touched here.
create function public.update_project(
  p_project_id uuid, p_title text default null, p_description text default null,
  p_visibility public.visibility default null, p_license public.license_type default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
begin
  update public.projects
     set title       = coalesce(trim(p_title), title),
         description = coalesce(nullif(trim(p_description), ''), description),
         visibility  = coalesce(p_visibility, visibility),
         license     = coalesce(p_license, license),
         updated_at  = now()
   where id = p_project_id and owner_id = v_uid;
  if not found then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
end;
$$;

-- §4.3 step 4c. Called only by the server (service role) after it verified uploads in R2.
--   p_upserts  [{"path": text, "hash": hex}]   files added or changed relative to the parent
--   p_deletes  text[]                          paths removed relative to the parent
--   p_verified [{"hash": hex, "size": bigint}] hashes the server proved this actor uploaded (size from R2)
-- Errors: USERNAME_REQUIRED, NOT_AUTHORIZED, COPY_FROZEN, INVALID_PARENT, INVALID_MANIFEST,
--         HASH_NOT_VERIFIED, TOO_MANY_FILES, QUOTA_EXCEEDED, STALE_PARENT.
create function public.commit_version(
  p_actor uuid, p_project_id uuid, p_copy_id bigint, p_parent_id bigint, p_note text,
  p_upserts jsonb, p_deletes text[], p_verified jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_quota constant bigint := 500 * 1024 * 1024;   -- USER_QUOTA_BYTES in lib/limits.js
  v_uid uuid := public.require_actor(p_actor);
  v_project public.projects;
  v_copy public.copies;
  v_parent_paths text[] := '{}';
  v_parent_hashes bytea[] := '{}';
  v_paths text[];
  v_hashes bytea[];
  v_new_bytes bigint;
  v_version_id bigint;
  v_up_paths text[];
  v_up_hashes bytea[];
  v_ver_hashes bytea[];
  v_ver_sizes bigint[];
begin
  select * into v_project from public.projects where id = p_project_id;
  if not found then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;

  if p_copy_id is null then
    if v_project.owner_id <> v_uid then
      raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
    end if;
  else
    select * into v_copy from public.copies where id = p_copy_id and project_id = p_project_id;
    if not found or v_copy.author_id <> v_uid then
      raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
    end if;
    -- Frozen while a request is pending and once published; editable during changes_requested.
    if v_copy.state = 'published'
       or (v_copy.state = 'in_review' and not exists (
             select 1 from public.review_requests
             where copy_id = p_copy_id and status = 'changes_requested')) then
      raise exception 'COPY_FROZEN' using errcode = 'P0001';
    end if;
  end if;

  if p_parent_id is not null then
    select file_paths, file_hashes into v_parent_paths, v_parent_hashes
      from public.versions where id = p_parent_id and project_id = p_project_id;
    if not found then
      raise exception 'INVALID_PARENT' using errcode = 'P0001';
    end if;
  end if;

  -- Parse input once into parallel arrays.
  begin
    select coalesce(array_agg(u ->> 'path'), '{}'), coalesce(array_agg(decode(u ->> 'hash', 'hex')), '{}')
      into v_up_paths, v_up_hashes
      from jsonb_array_elements(coalesce(p_upserts, '[]')) u;
    select coalesce(array_agg(decode(v ->> 'hash', 'hex')), '{}'), coalesce(array_agg((v ->> 'size')::bigint), '{}')
      into v_ver_hashes, v_ver_sizes
      from jsonb_array_elements(coalesce(p_verified, '[]')) v;
  exception
    when others then
      raise exception 'INVALID_MANIFEST' using errcode = 'P0001';
  end;

  if exists (select 1 from unnest(v_up_paths, v_up_hashes) u(path, hash)
             where path is null or path = '' or char_length(path) > 1024 or hash is null or octet_length(hash) <> 32)
     or cardinality(v_up_paths) <> (select count(distinct x) from unnest(v_up_paths) x)
     or exists (select 1 from unnest(v_ver_hashes, v_ver_sizes) v(hash, size)
                where hash is null or octet_length(hash) <> 32 or size is null or size < 0) then
    raise exception 'INVALID_MANIFEST' using errcode = 'P0001';
  end if;

  -- F6/F11: reuse without upload only for hashes already in the parent manifest.
  if exists (select 1 from unnest(v_up_hashes) h
             where h <> all (v_parent_hashes) and h <> all (v_ver_hashes)) then
    raise exception 'HASH_NOT_VERIFIED' using errcode = 'P0001';
  end if;

  -- New blobs; quota is charged only for rows actually inserted.
  with ins as (
    insert into public.blobs (hash, size, uploaded_by)
    select distinct on (hash) hash, size, v_uid from unnest(v_ver_hashes, v_ver_sizes) v(hash, size)
    on conflict (hash) do nothing
    returning size
  )
  select coalesce(sum(size), 0) into v_new_bytes from ins;

  if v_new_bytes > 0 then
    update public.profiles set storage_used = storage_used + v_new_bytes
     where id = v_uid and storage_used + v_new_bytes <= c_quota;
    if not found then
      raise exception 'QUOTA_EXCEEDED' using errcode = 'P0001';
    end if;
  end if;

  -- New manifest = parent − deletes − upserted paths + upserts, sorted by path.
  select coalesce(array_agg(path order by path), '{}'), coalesce(array_agg(hash order by path), '{}')
    into v_paths, v_hashes
  from (
    select p.path, p.hash
      from unnest(v_parent_paths, v_parent_hashes) as p(path, hash)
     where p.path <> all (coalesce(p_deletes, '{}'))
       and p.path <> all (v_up_paths)
    union all
    select path, hash from unnest(v_up_paths, v_up_hashes) u(path, hash)
  ) m;

  if cardinality(v_paths) > 1000 then   -- MAX_FILES_PER_VERSION
    raise exception 'TOO_MANY_FILES' using errcode = 'P0001';
  end if;

  insert into public.versions (project_id, copy_id, parent_id, author_id, note, file_paths, file_hashes)
  values (p_project_id, p_copy_id, p_parent_id, v_uid, nullif(trim(p_note), ''), v_paths, v_hashes)
  returning id into v_version_id;

  -- Optimistic pointer advance: someone else saved first → STALE_PARENT (whole transaction rolls back).
  if p_copy_id is null then
    update public.projects set main_version_id = v_version_id, updated_at = now()
     where id = p_project_id and main_version_id is not distinct from p_parent_id;
    if not found then
      raise exception 'STALE_PARENT' using errcode = 'P0001';
    end if;
    insert into public.main_history (project_id, version_id, promoted_by)
    values (p_project_id, v_version_id, v_uid);
  else
    update public.copies set head_version_id = v_version_id
     where id = p_copy_id and head_version_id = p_parent_id;
    if not found then
      raise exception 'STALE_PARENT' using errcode = 'P0001';
    end if;
  end if;

  return v_version_id;
end;
$$;

-- New main version with an old main version's manifest. No new blobs, so no quota change.
create function public.restore_version(p_project_id uuid, p_version_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
  v_current bigint;
  v_old public.versions;
  v_new bigint;
begin
  select main_version_id into v_current from public.projects where id = p_project_id and owner_id = v_uid;
  if not found then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
  -- Only versions that were on the main line of this project can be restored.
  if not exists (select 1 from public.main_history where project_id = p_project_id and version_id = p_version_id) then
    raise exception 'INVALID_VERSION' using errcode = 'P0001';
  end if;
  select * into v_old from public.versions where id = p_version_id;

  insert into public.versions (project_id, parent_id, author_id, note, file_paths, file_hashes)
  values (p_project_id, v_current, v_uid, 'Restored from version ' || p_version_id, v_old.file_paths, v_old.file_hashes)
  returning id into v_new;

  update public.projects set main_version_id = v_new, updated_at = now()
   where id = p_project_id and main_version_id is not distinct from v_current;
  if not found then
    raise exception 'STALE_PARENT' using errcode = 'P0001';
  end if;
  insert into public.main_history (project_id, version_id, promoted_by) values (p_project_id, v_new, v_uid);
  return v_new;
end;
$$;

-- "Make my copy": private draft on top of the current main.
create function public.make_copy(p_project_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
  v_project public.projects;
  v_id bigint;
begin
  select * into v_project from public.projects where id = p_project_id;
  if not found or v_project.visibility <> 'public' then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
  if v_project.owner_id = v_uid then
    raise exception 'OWN_PROJECT' using errcode = 'P0001';
  end if;
  if v_project.license = 'all_rights_reserved' then
    raise exception 'LICENSE_FORBIDS_COPY' using errcode = 'P0001';
  end if;
  if v_project.main_version_id is null then
    raise exception 'NO_MAIN_VERSION' using errcode = 'P0001';
  end if;

  insert into public.copies (project_id, author_id, project_owner_id, base_version_id, head_version_id)
  values (p_project_id, v_uid, v_project.owner_id, v_project.main_version_id, v_project.main_version_id)
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.create_project(text, text, public.project_type, public.visibility, public.license_type) from public, anon;
revoke execute on function public.update_project(uuid, text, text, public.visibility, public.license_type) from public, anon;
revoke execute on function public.commit_version(uuid, uuid, bigint, bigint, text, jsonb, text[], jsonb) from public, anon, authenticated;
revoke execute on function public.restore_version(uuid, bigint) from public, anon;
revoke execute on function public.make_copy(uuid) from public, anon;

grant execute on function public.create_project(text, text, public.project_type, public.visibility, public.license_type) to authenticated;
grant execute on function public.update_project(uuid, text, text, public.visibility, public.license_type) to authenticated;
grant execute on function public.commit_version(uuid, uuid, bigint, bigint, text, jsonb, text[], jsonb) to service_role;
grant execute on function public.restore_version(uuid, bigint) to authenticated;
grant execute on function public.make_copy(uuid) to authenticated;
