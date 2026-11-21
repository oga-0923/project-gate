-- New Supabase projects don't expose new tables to the API automatically.
-- Logged-in players may read/write their own save and read their own wallet & history
-- (row-level security policies still limit every row to its owner).
grant usage on schema public to authenticated;
grant select, insert, update on public.saves to authenticated;
grant select on public.wallets, public.purchases, public.porta_ledger, public.grants to authenticated;
revoke all on public.saves, public.wallets, public.purchases, public.porta_ledger, public.grants from anon;
