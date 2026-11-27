-- The shop a receipt is from ("Mercator", "Lidl"...), read from the receipt photo or typed in,
-- so grocery prices can be compared shop by shop. Empty for entries without one. Apps that don't
-- know this column keep it, because an upsert only changes the columns it sends.
alter table public.transactions
  add column if not exists store text not null default '' check (char_length(store) <= 60);
