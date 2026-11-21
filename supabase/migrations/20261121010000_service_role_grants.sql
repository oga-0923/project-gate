-- The server (Edge Functions, service_role) needs table access too: this project
-- does not grant privileges on new tables automatically.
grant usage on schema public to service_role;
grant select, insert, update, delete on public.saves, public.wallets, public.purchases, public.porta_ledger, public.grants to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on function public.grant_purchase(uuid,text,integer,text,integer,boolean,integer,text,boolean),
  public.extend_pass(uuid,timestamptz,boolean), public.month_spent(uuid) to service_role;
