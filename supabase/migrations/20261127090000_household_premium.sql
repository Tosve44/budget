-- Premium for a household (phone apps from the App Store and Google Play). When one partner has
-- Premium, the whole household has it, so the other partner does not have to pay as well.
--
-- premium_until: Premium lasts until then. Empty means no Premium. 'infinity' is a free unlock
-- given by hand in the SQL editor (the testers).
--
-- Members cannot write the column directly. A phone whose store account has Premium calls
-- extend_household_premium() now and then, which keeps it going for 35 more days. When the
-- subscription ends, the phone stops calling and Premium runs out on its own.
alter table public.households add column if not exists premium_until timestamptz;

create or replace function public.extend_household_premium() returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare h uuid := public.my_household(); t timestamptz;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if h is null then raise exception 'not in a household' using errcode = 'P0002'; end if;
  update public.households
     set premium_until = greatest(coalesce(premium_until, now()), now() + interval '35 days')
   where id = h
  returning premium_until into t;
  return t;
end $$;

revoke execute on function public.extend_household_premium() from public, anon;
grant execute on function public.extend_household_premium() to authenticated;
