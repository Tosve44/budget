-- Budget app: cloud data for syncing two phones (web app and native app share this).
-- Paste this whole file into the Supabase SQL editor once (or run `supabase db push`).
--
-- Model (mirrors store.js schemaVersion 1):
--   households   one per couple; holds the invite code and the shared currency
--   members      who belongs to a household (max 2 people)
--   spaces       one 'house' space per household + one 'personal' space per member
--   categories   per space; soft-deleted, last-write-wins on updated_at
--   transactions per space; money in cents; receipt items as JSON; soft-deleted
-- Storage bucket 'receipts': photos at '<space_id>/<transaction_id>.jpg'.
--
-- Privacy: a personal space and everything in it is visible only to its owner.
-- The house space is visible to both members. Enforced by row level security.

-- ---------- tables ----------
create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Home' check (char_length(name) between 1 and 60),
  currency text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  server_updated_at timestamptz not null default now()
);

create table public.members (
  household_id uuid not null references public.households (id) on delete cascade,
  user_id uuid not null unique references auth.users (id) on delete cascade, -- one household per person
  display_name text not null check (char_length(display_name) between 1 and 40),
  joined_at timestamptz not null default now(),
  server_updated_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

create table public.spaces (
  id text primary key check (char_length(id) between 3 and 64),
  household_id uuid not null references public.households (id) on delete cascade,
  type text not null check (type in ('personal', 'house')),
  name text not null check (char_length(name) between 1 and 40),
  owner_id uuid references auth.users (id) on delete cascade,
  server_updated_at timestamptz not null default now(),
  check ((type = 'personal') = (owner_id is not null))
);
create unique index spaces_one_house on public.spaces (household_id) where type = 'house';
create unique index spaces_one_personal on public.spaces (owner_id) where type = 'personal';

create table public.categories (
  id text primary key check (char_length(id) between 3 and 64),
  space_id text not null references public.spaces (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  kind text not null check (kind in ('expense', 'income')),
  budget bigint not null default 0 check (budget >= 0 and budget < 100000000000), -- cents per month
  sort_order integer not null default 0,
  archived boolean not null default false,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),        -- when a phone changed it (conflicts: newest wins)
  server_updated_at timestamptz not null default now()  -- set by the server; phones pull rows newer than their last pull
);
create index categories_pull on public.categories (server_updated_at);

create table public.transactions (
  id text primary key check (char_length(id) between 3 and 64),
  space_id text not null references public.spaces (id) on delete cascade,
  category_id text not null references public.categories (id),
  kind text not null check (kind in ('expense', 'income')),
  amount bigint not null check (amount > 0 and amount < 100000000000), -- cents
  date date not null,
  note text not null default '' check (char_length(note) <= 500),
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) <= 300),
  receipt_path text check (receipt_path is null or receipt_path = space_id || '/' || id || '.jpg'),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  server_updated_at timestamptz not null default now()
);
create index transactions_pull on public.transactions (server_updated_at);
create index transactions_space_date on public.transactions (space_id, date);

-- ---------- helpers ----------
create function public.my_household() returns uuid
language sql stable security definer set search_path = '' as $$
  select household_id from public.members where user_id = auth.uid()
$$;

create function public.can_access_space(sid text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.spaces s
    where s.id = sid
      and s.household_id = public.my_household()
      and (s.type = 'house' or s.owner_id = auth.uid())
  )
$$;

-- Server clock for pulling changes; ignore a write that is older than what the server has
-- (two phones edited the same row: the most recent edit wins).
create function public.touch_row() returns trigger
language plpgsql as $$
begin
  -- The author of a new entry is always the signed-in person. (Set here rather than only
  -- checked, because a phone uploading the partner's edited entry sends an "insert or
  -- update", and Postgres checks the insert rules even when the row already exists.)
  if tg_op = 'INSERT' and tg_table_name = 'transactions' and auth.uid() is not null then
    new.created_by := auth.uid();
  end if;
  if tg_op = 'UPDATE' and tg_table_name in ('categories', 'transactions') then
    if new.updated_at < old.updated_at then
      return null; -- stale edit from a phone that was offline: keep the newer server version
    end if;
    if tg_table_name = 'transactions' then
      new.created_by := old.created_by; -- who added an entry never changes
      new.created_at := old.created_at;
    end if;
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end $$;

create trigger touch before insert or update on public.households for each row execute function public.touch_row();
create trigger touch before insert or update on public.members for each row execute function public.touch_row();
create trigger touch before insert or update on public.spaces for each row execute function public.touch_row();
create trigger touch before insert or update on public.categories for each row execute function public.touch_row();
create trigger touch before insert or update on public.transactions for each row execute function public.touch_row();

-- A transaction's category must be in the same space.
create function public.check_tx_category() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.categories c where c.id = new.category_id and c.space_id = new.space_id) then
    raise exception 'category % is not in space %', new.category_id, new.space_id using errcode = '23514';
  end if;
  return new;
end $$;
create trigger tx_category before insert or update of category_id, space_id on public.transactions
  for each row execute function public.check_tx_category();

-- ---------- row level security ----------
alter table public.households enable row level security;
alter table public.members enable row level security;
alter table public.spaces enable row level security;
alter table public.categories enable row level security;
alter table public.transactions enable row level security;

create policy "members read their household" on public.households for select to authenticated
  using (id = public.my_household());
create policy "members update their household" on public.households for update to authenticated
  using (id = public.my_household()) with check (id = public.my_household());

create policy "read household members" on public.members for select to authenticated
  using (household_id = public.my_household());
create policy "rename myself" on public.members for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and household_id = public.my_household());

create policy "read my spaces" on public.spaces for select to authenticated
  using (public.can_access_space(id));

create policy "read categories" on public.categories for select to authenticated
  using (public.can_access_space(space_id));
create policy "add categories" on public.categories for insert to authenticated
  with check (public.can_access_space(space_id));
create policy "edit categories" on public.categories for update to authenticated
  using (public.can_access_space(space_id)) with check (public.can_access_space(space_id));

create policy "read transactions" on public.transactions for select to authenticated
  using (public.can_access_space(space_id));
create policy "add transactions" on public.transactions for insert to authenticated
  with check (public.can_access_space(space_id) and created_by = auth.uid());
create policy "edit transactions" on public.transactions for update to authenticated
  using (public.can_access_space(space_id)) with check (public.can_access_space(space_id));
-- No delete policies: phones mark rows deleted = true so the other phone learns about it.

-- Lock down what the anonymous (not signed in) role can touch.
revoke all on public.households, public.members, public.spaces, public.categories, public.transactions from anon;
-- Columns the server manages cannot be written by phones.
revoke insert, update on public.households from authenticated;
grant update (name, currency) on public.households to authenticated;
revoke insert, update on public.members from authenticated;
grant update (display_name) on public.members to authenticated;
revoke insert, update, delete on public.spaces from authenticated;
revoke delete on public.categories, public.transactions from authenticated;

-- ---------- sign-up flow: create a household, or join one with its invite code ----------
create function public.create_household(display_name text, house_space_id text, personal_space_id text)
returns public.households
language plpgsql security definer set search_path = '' as $$
declare h public.households;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then
    raise exception 'already in a household' using errcode = '23505';
  end if;
  insert into public.households (created_by) values (auth.uid()) returning * into h;
  insert into public.members (household_id, user_id, display_name) values (h.id, auth.uid(), display_name);
  insert into public.spaces (id, household_id, type, name, owner_id) values
    (house_space_id, h.id, 'house', 'House', null),
    (personal_space_id, h.id, 'personal', 'Personal', auth.uid());
  return h;
end $$;

create function public.join_household(code text, display_name text, personal_space_id text)
returns public.households
language plpgsql security definer set search_path = '' as $$
declare h public.households;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then
    raise exception 'already in a household' using errcode = '23505';
  end if;
  select * into h from public.households where invite_code = upper(trim(code)) for update;
  if h.id is null then raise exception 'invite code not found' using errcode = 'P0002'; end if;
  if (select count(*) from public.members where household_id = h.id) >= 2 then
    raise exception 'household is full' using errcode = '23514';
  end if;
  insert into public.members (household_id, user_id, display_name) values (h.id, auth.uid(), display_name);
  insert into public.spaces (id, household_id, type, name, owner_id) values
    (personal_space_id, h.id, 'personal', 'Personal', auth.uid());
  return h;
end $$;

revoke execute on function public.create_household(text, text, text) from public, anon;
revoke execute on function public.join_household(text, text, text) from public, anon;
grant execute on function public.create_household(text, text, text) to authenticated;
grant execute on function public.join_household(text, text, text) to authenticated;
revoke execute on function public.my_household() from public, anon;
revoke execute on function public.can_access_space(text) from public, anon;
grant execute on function public.my_household() to authenticated;
grant execute on function public.can_access_space(text) to authenticated;

-- ---------- receipt photos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 3145728, array['image/jpeg'])
on conflict (id) do nothing;

create policy "read receipts" on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and public.can_access_space((storage.foldername(name))[1]));
create policy "upload receipts" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and public.can_access_space((storage.foldername(name))[1]));
create policy "replace receipts" on storage.objects for update to authenticated
  using (bucket_id = 'receipts' and public.can_access_space((storage.foldername(name))[1]))
  with check (bucket_id = 'receipts' and public.can_access_space((storage.foldername(name))[1]));
create policy "delete receipts" on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and public.can_access_space((storage.foldername(name))[1]));
