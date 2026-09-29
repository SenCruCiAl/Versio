-- Versio schema (BACKEND_PLAN.md §5).
-- B1 adds profiles only; B2 extends this file with the remaining tables, enums and indexes.

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
