-- Requests to publish, review, promote, notifications (BACKEND_PLAN.md §6, B5–B7 database side).

-- Inserts a notification and pushes it on the user's private Broadcast channel (E7).
create function public.notify(p_user_id uuid, p_type text, p_ref_id text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.notifications (user_id, type, ref_id, payload)
  values (p_user_id, p_type, p_ref_id, coalesce(p_payload, '{}'))
  returning id into v_id;
  perform realtime.send(
    jsonb_build_object('id', v_id, 'type', p_type, 'ref_id', p_ref_id, 'payload', coalesce(p_payload, '{}')),
    'notification', 'user:' || p_user_id::text, true);
end;
$$;
revoke execute on function public.notify(uuid, text, text, jsonb) from public, anon, authenticated;

-- Copy author asks the owner to publish the copy. Errors: NOT_AUTHORIZED, INVALID_STATE.
create function public.submit_request(p_copy_id bigint, p_note text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
  v_copy public.copies;
  v_id bigint;
begin
  select * into v_copy from public.copies where id = p_copy_id for update;
  if not found or v_copy.author_id <> v_uid then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
  if v_copy.state <> 'private' then
    raise exception 'INVALID_STATE' using errcode = 'P0001';
  end if;

  insert into public.review_requests (copy_id, project_id, owner_id, contributor_id, submitted_version_id)
  values (p_copy_id, v_copy.project_id, v_copy.project_owner_id, v_uid, v_copy.head_version_id)
  returning id into v_id;
  insert into public.request_events (request_id, actor_id, kind, version_id, comment)
  values (v_id, v_uid, 'submitted', v_copy.head_version_id, nullif(trim(p_note), ''));
  update public.copies set state = 'in_review' where id = p_copy_id;
  perform public.notify(v_copy.project_owner_id, 'request_submitted', v_id::text,
                        jsonb_build_object('copy_id', p_copy_id, 'project_id', v_copy.project_id));
  return v_id;
end;
$$;

-- After "ask for changes", the contributor sends the copy's current head back for review.
create function public.resubmit_request(p_request_id bigint, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
  v_req public.review_requests;
  v_head bigint;
begin
  select * into v_req from public.review_requests where id = p_request_id for update;
  if not found or v_req.contributor_id <> v_uid then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
  if v_req.status <> 'changes_requested' then
    raise exception 'INVALID_STATE' using errcode = 'P0001';
  end if;

  select head_version_id into v_head from public.copies where id = v_req.copy_id;
  update public.review_requests
     set status = 'pending', submitted_version_id = v_head, updated_at = now()
   where id = p_request_id;
  insert into public.request_events (request_id, actor_id, kind, version_id, comment)
  values (p_request_id, v_uid, 'resubmitted', v_head, nullif(trim(p_note), ''));
  perform public.notify(v_req.owner_id, 'request_resubmitted', p_request_id::text,
                        jsonb_build_object('copy_id', v_req.copy_id, 'project_id', v_req.project_id));
end;
$$;

-- Owner decides on a pending request: 'approve' | 'request_changes' | 'reject'.
create function public.review_request(p_request_id bigint, p_decision text, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
  v_req public.review_requests;
  v_status public.request_status;
  v_kind public.request_event_kind;
begin
  select * into v_req from public.review_requests where id = p_request_id for update;
  if not found or v_req.owner_id <> v_uid then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'INVALID_STATE' using errcode = 'P0001';
  end if;
  -- The copy must still be at the submitted version (saves are frozen while pending, so this holds).

  case p_decision
    when 'approve' then
      v_status := 'approved'; v_kind := 'approved';
      update public.copies set state = 'published', published_at = now(),
                               head_version_id = v_req.submitted_version_id
       where id = v_req.copy_id;
    when 'request_changes' then
      v_status := 'changes_requested'; v_kind := 'changes_requested';   -- copy stays in_review, author may save
    when 'reject' then
      v_status := 'rejected'; v_kind := 'rejected';
      update public.copies set state = 'private' where id = v_req.copy_id;
    else
      raise exception 'INVALID_DECISION' using errcode = 'P0001';
  end case;

  update public.review_requests
     set status = v_status, updated_at = now(),
         resolved_at = case when v_status in ('approved', 'rejected') then now() end
   where id = p_request_id;
  insert into public.request_events (request_id, actor_id, kind, version_id, comment)
  values (p_request_id, v_uid, v_kind, v_req.submitted_version_id, nullif(trim(p_comment), ''));
  perform public.notify(v_req.contributor_id, 'request_' || v_kind::text, p_request_id::text,
                        jsonb_build_object('copy_id', v_req.copy_id, 'project_id', v_req.project_id));
end;
$$;

-- Owner makes a published copy the new main (pointer update, no file copying; F10 stale guard).
create function public.promote_copy(p_copy_id bigint, p_acknowledge_stale boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_actor(auth.uid());
  v_copy public.copies;
  v_main bigint;
begin
  select * into v_copy from public.copies where id = p_copy_id;
  if not found or v_copy.project_owner_id <> v_uid then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
  if v_copy.state <> 'published' then
    raise exception 'INVALID_STATE' using errcode = 'P0001';
  end if;

  select main_version_id into v_main from public.projects where id = v_copy.project_id for update;
  if v_copy.base_version_id is distinct from v_main and not p_acknowledge_stale then
    raise exception 'STALE_COPY' using errcode = 'P0001';
  end if;

  update public.projects set main_version_id = v_copy.head_version_id, updated_at = now()
   where id = v_copy.project_id;
  insert into public.main_history (project_id, version_id, promoted_by, from_copy_id)
  values (v_copy.project_id, v_copy.head_version_id, v_uid, p_copy_id);
  perform public.notify(v_copy.author_id, 'copy_promoted', p_copy_id::text,
                        jsonb_build_object('project_id', v_copy.project_id));
end;
$$;

-- Marks the caller's notifications read and keeps at most the newest 100 read ones.
create function public.mark_notifications_read(p_ids bigint[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = 'P0001';
  end if;
  update public.notifications set read = true
   where user_id = v_uid and id = any (p_ids) and not read;
  delete from public.notifications
   where user_id = v_uid and read
     and id < coalesce((select id from public.notifications
                         where user_id = v_uid and read
                         order by id desc offset 99 limit 1), 0);
end;
$$;

revoke execute on function public.submit_request(bigint, text) from public, anon;
revoke execute on function public.resubmit_request(bigint, text) from public, anon;
revoke execute on function public.review_request(bigint, text, text) from public, anon;
revoke execute on function public.promote_copy(bigint, boolean) from public, anon;
revoke execute on function public.mark_notifications_read(bigint[]) from public, anon;
grant execute on function public.submit_request(bigint, text) to authenticated;
grant execute on function public.resubmit_request(bigint, text) to authenticated;
grant execute on function public.review_request(bigint, text, text) to authenticated;
grant execute on function public.promote_copy(bigint, boolean) to authenticated;
grant execute on function public.mark_notifications_read(bigint[]) to authenticated;
