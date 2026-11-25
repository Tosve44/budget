// Supabase project the app syncs with. Both values are public by design (they ship inside
// the app); privacy comes from the row level security rules in supabase/migrations.
// Leave empty to use the app on one phone only, without syncing.
export const CONFIG = {
  supabaseUrl: '',
  supabaseAnonKey: '',
};
