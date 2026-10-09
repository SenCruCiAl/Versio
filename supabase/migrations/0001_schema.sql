-- Versio schema (BACKEND_PLAN.md §5): tables, enums, indexes.

create extension if not exists citext with schema extensions;

create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  username      extensions.citext unique,
  display_name  text,
  avatar_url    text,
  tags          text[] not null default '{}',
  storage_used  bigint not null default 0 check (storage_used >= 0),
  created_at    timestamptz not null default now(),
  constraint profiles_username_format check (username is null or username::text ~ '^[a-z0-9_]{3,30}$')
);

create type public.project_type       as enum ('writing', 'code', 'cad');
create type public.visibility         as enum ('public', 'private');
create type public.license_type       as enum ('cc_by', 'cc_by_sa', 'cc_by_nc', 'mit', 'all_rights_reserved');
create type public.copy_state         as enum ('private', 'in_review', 'published');
create type public.request_status     as enum ('pending', 'changes_requested', 'approved', 'rejected');
create type public.request_event_kind as enum ('submitted', 'changes_requested', 'resubmitted', 'approved', 'rejected');

create table public.projects (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.profiles (id) on delete cascade,
  title            text not null check (char_length(title) between 1 and 120),
  description      text check (char_length(description) <= 2000),
  type             public.project_type not null,
  visibility       public.visibility not null default 'public',
  license          public.license_type not null,
  main_version_id  bigint,              -- FK added below; null only before the first save
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table public.copies (
  id                bigint generated always as identity primary key,
  project_id        uuid not null references public.projects (id) on delete cascade,
  author_id         uuid not null references public.profiles (id) on delete cascade,
  project_owner_id  uuid not null references public.profiles (id) on delete cascade,  -- denormalized for RLS (E4)
  state             public.copy_state not null default 'private',
  base_version_id   bigint not null,
  head_version_id   bigint not null,
  published_at      timestamptz,
  created_at        timestamptz not null default now(),
  constraint copies_not_own_project check (author_id <> project_owner_id),
  constraint copies_published_at check ((state = 'published') = (published_at is not null))
);

create table public.versions (
  id           bigint generated always as identity primary key,   -- time-ordered: order by id desc
  project_id   uuid not null references public.projects (id) on delete cascade,
  copy_id      bigint references public.copies (id) on delete cascade,  -- null = main line
  parent_id    bigint references public.versions (id) on delete set null,
  author_id    uuid not null references public.profiles (id) on delete cascade,
  note         text check (char_length(note) <= 2000),
  file_paths   text[] not null,      -- sorted by path, same length as file_hashes
  file_hashes  bytea[] not null,
  created_at   timestamptz not null default now(),
  constraint versions_manifest_lengths check (cardinality(file_paths) = cardinality(file_hashes)),
  constraint versions_max_files check (cardinality(file_paths) <= 1000)   -- MAX_FILES_PER_VERSION
);

alter table public.projects
  add constraint projects_main_version_fk foreign key (main_version_id) references public.versions (id);
alter table public.copies
  add constraint copies_base_version_fk foreign key (base_version_id) references public.versions (id),
  add constraint copies_head_version_fk foreign key (head_version_id) references public.versions (id);

create table public.blobs (
  hash         bytea primary key check (octet_length(hash) = 32),   -- R2 key: 'objects/' || encode(hash, 'hex')
  size         bigint not null check (size >= 0),
  mime         text,
  uploaded_by  uuid references public.profiles (id) on delete set null,
  blocked_at   timestamptz,
  created_at   timestamptz not null default now()
);

create table public.review_requests (
  id                    bigint generated always as identity primary key,
  copy_id               bigint not null references public.copies (id) on delete cascade,
  project_id            uuid not null references public.projects (id) on delete cascade,
  owner_id              uuid not null references public.profiles (id) on delete cascade,
  contributor_id        uuid not null references public.profiles (id) on delete cascade,
  submitted_version_id  bigint not null references public.versions (id),
  status                public.request_status not null default 'pending',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  resolved_at           timestamptz
);

create table public.request_events (
  id          bigint generated always as identity primary key,
  request_id  bigint not null references public.review_requests (id) on delete cascade,
  actor_id    uuid not null references public.profiles (id) on delete cascade,
  kind        public.request_event_kind not null,
  version_id  bigint references public.versions (id),
  comment     text check (char_length(comment) <= 4000),
  created_at  timestamptz not null default now()
);

create table public.main_history (
  id            bigint generated always as identity primary key,
  project_id    uuid not null references public.projects (id) on delete cascade,
  version_id    bigint not null references public.versions (id),
  promoted_by   uuid not null references public.profiles (id) on delete cascade,
  from_copy_id  bigint references public.copies (id) on delete set null,
  created_at    timestamptz not null default now()
);

create table public.notifications (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  type        text not null,
  ref_id      text,
  payload     jsonb not null default '{}',
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Indexes (§5), plus FK columns that RLS or cascades look up.
create unique index review_requests_one_open_per_copy
  on public.review_requests (copy_id) where status in ('pending', 'changes_requested');
create index projects_owner_idx          on public.projects (owner_id);
create index copies_project_state_idx    on public.copies (project_id, state);
create index copies_author_idx           on public.copies (author_id);
create index versions_project_copy_idx   on public.versions (project_id, copy_id, id desc);
create index versions_copy_idx           on public.versions (copy_id) where copy_id is not null;
create index versions_parent_idx         on public.versions (parent_id);
create index review_requests_owner_idx   on public.review_requests (owner_id, status, id desc);
create index review_requests_contrib_idx on public.review_requests (contributor_id, status, id desc);
create index request_events_request_idx  on public.request_events (request_id, id);
create index main_history_project_idx    on public.main_history (project_id, id desc);
create index notifications_unread_idx    on public.notifications (user_id, id desc) where not read;
create index notifications_user_idx      on public.notifications (user_id, id desc);
