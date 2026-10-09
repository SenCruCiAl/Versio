-- Step 1 check (5): private-channel Broadcast from Postgres via realtime.send().
-- Run: npx supabase db query --file scripts/spike/broadcast.sql   (or paste into Studio's SQL editor)
-- PASS when the insert into realtime.messages succeeds and the row is marked private.
-- A live end-to-end check (a subscribed client receives it) is done in B7 with the notifications RPCs.
begin;

select realtime.send(
  jsonb_build_object('spike', true, 'at', now()),
  'spike_event',
  'user:00000000-0000-0000-0000-00000000000a',
  true  -- private channel: subscribers need a realtime.messages RLS policy
);

select case when count(*) = 1 then 'PASS: realtime.send wrote a private broadcast message'
            else 'FAIL: no private message row' end as result
from realtime.messages
where topic = 'user:00000000-0000-0000-0000-00000000000a' and event = 'spike_event' and private;

rollback;
