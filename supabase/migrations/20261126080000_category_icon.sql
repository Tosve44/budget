-- Category icons: an emoji a person picked for a category. Empty means "use the default icon
-- for the category's name" (the list is in store.js, categoryIcon). Apps that don't know this
-- column keep it, because an upsert only changes the columns it sends.
alter table public.categories
  add column if not exists icon text not null default '' check (char_length(icon) <= 16);
