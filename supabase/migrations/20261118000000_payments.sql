-- PROJECT GATE: accounts, cloud save and Stripe payments.
-- Paid Porta, purchases and the Gate Pass live here and can only be changed by
-- the server (Edge Functions with the service role) or by the narrow RPCs below.

-- ---------- Cloud save (players read/write only their own) ----------
create table if not exists public.saves (
  user_id    uuid primary key references auth.users on delete cascade,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.saves enable row level security;
create policy "saves: read own"   on public.saves for select using (auth.uid() = user_id);
create policy "saves: insert own" on public.saves for insert with check (auth.uid() = user_id);
create policy "saves: update own" on public.saves for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- Wallet (read-only for players) ----------
create table if not exists public.wallets (
  user_id         uuid primary key references auth.users on delete cascade,
  paid            integer not null default 0 check (paid >= 0),      -- 有償ポルタ残高
  age_group       text check (age_group in ('u16','u18','adult')),
  pass_until      timestamptz,
  trial_used      boolean not null default false,
  starter_bought  boolean not null default false,
  first_bought    text[]  not null default '{}',                     -- 初回2倍を使った商品
  stripe_customer text unique,
  updated_at      timestamptz not null default now()
);
alter table public.wallets enable row level security;
create policy "wallets: read own" on public.wallets for select using (auth.uid() = user_id);

-- ---------- Purchases (one row per Stripe payment; read-only for players) ----------
create table if not exists public.purchases (
  id         bigserial primary key,
  user_id    uuid not null references auth.users on delete cascade,
  product    text not null,
  yen        integer not null check (yen >= 0),
  porta      integer not null default 0,
  stripe_ref text not null unique,                                   -- checkout session / invoice id
  created_at timestamptz not null default now()
);
create index if not exists purchases_user_month on public.purchases (user_id, created_at);
alter table public.purchases enable row level security;
create policy "purchases: read own" on public.purchases for select using (auth.uid() = user_id);

-- ---------- Paid Porta ledger (資金決済法: 未使用残高の把握) ----------
create table if not exists public.porta_ledger (
  id         bigserial primary key,
  user_id    uuid not null references auth.users on delete cascade,
  delta      integer not null,
  balance    integer not null,
  reason     text not null,
  ref        text,
  created_at timestamptz not null default now()
);
create index if not exists porta_ledger_user on public.porta_ledger (user_id, created_at);
alter table public.porta_ledger enable row level security;
create policy "ledger: read own" on public.porta_ledger for select using (auth.uid() = user_id);

-- ---------- Items to hand to the game after a purchase (packs, frames) ----------
create table if not exists public.grants (
  id         bigserial primary key,
  user_id    uuid not null references auth.users on delete cascade,
  kind       text not null check (kind in ('packs','item')),
  amount     integer not null default 0,
  item       text,
  ref        text,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.grants enable row level security;
create policy "grants: read own" on public.grants for select using (auth.uid() = user_id);

-- =====================================================================
-- Player-callable functions
-- =====================================================================

-- Returns (and creates on first call) the caller's wallet.
create or replace function public.my_wallet()
returns public.wallets language plpgsql security definer set search_path = public as $$
declare w public.wallets;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into wallets (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select * into w from wallets where user_id = auth.uid();
  return w;
end $$;

-- Age group can be set once (changing it needs support).
create or replace function public.set_age_group(g text)
returns public.wallets language plpgsql security definer set search_path = public as $$
declare w public.wallets;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if g not in ('u16','u18','adult') then raise exception 'bad age group'; end if;
  insert into wallets (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  update wallets set age_group = g, updated_at = now() where user_id = auth.uid() and age_group is null;
  select * into w from wallets where user_id = auth.uid();
  return w;
end $$;

-- Spend paid Porta. Fails (and changes nothing) if the balance is too low.
create or replace function public.spend_porta(n integer, reason text)
returns integer language plpgsql security definer set search_path = public as $$
declare bal integer;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if n is null or n <= 0 or n > 100000 then raise exception 'bad amount'; end if;
  update wallets set paid = paid - n, updated_at = now()
    where user_id = auth.uid() and paid >= n
    returning paid into bal;
  if bal is null then raise exception 'insufficient porta'; end if;
  insert into porta_ledger (user_id, delta, balance, reason) values (auth.uid(), -n, bal, left(coalesce(reason,'spend'), 40));
  return bal;
end $$;

-- Hand over (and mark as received) every unclaimed purchase item.
create or replace function public.claim_grants()
returns setof public.grants language sql security definer set search_path = public as $$
  update grants set claimed_at = now()
   where user_id = auth.uid() and claimed_at is null
  returning *;
$$;

-- Yen spent this calendar month (Japan time), for the under-18 limits.
create or replace function public.month_spent(uid uuid)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(yen), 0)::integer from purchases
   where user_id = uid
     and created_at >= date_trunc('month', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
$$;

create or replace function public.my_month_spent()
returns integer language sql stable security definer set search_path = public as $$
  select public.month_spent(auth.uid());
$$;

-- =====================================================================
-- Server-only (called by the Stripe webhook with the service role)
-- =====================================================================

-- Records a payment and grants its contents exactly once per Stripe reference.
create or replace function public.grant_purchase(
  p_user uuid, p_product text, p_yen integer, p_ref text,
  p_porta integer, p_first_double boolean, p_packs integer, p_item text, p_starter boolean)
returns integer language plpgsql security definer set search_path = public as $$
declare given integer := 0; bal integer; is_first boolean;
begin
  insert into wallets (user_id) values (p_user) on conflict (user_id) do nothing;
  begin
    insert into purchases (user_id, product, yen, porta, stripe_ref) values (p_user, p_product, p_yen, 0, p_ref);
  exception when unique_violation then
    return -1;  -- already processed (Stripe retries webhooks)
  end;
  if p_porta > 0 then
    select not (p_product = any(first_bought)) into is_first from wallets where user_id = p_user for update;
    given := case when p_first_double and is_first then p_porta * 2 else p_porta end;
    update wallets set paid = paid + given,
           first_bought = case when p_first_double and is_first then array_append(first_bought, p_product) else first_bought end,
           updated_at = now()
     where user_id = p_user returning paid into bal;
    insert into porta_ledger (user_id, delta, balance, reason, ref) values (p_user, given, bal, 'buy:' || p_product, p_ref);
    update purchases set porta = given where stripe_ref = p_ref;
  end if;
  if p_packs > 0 then insert into grants (user_id, kind, amount, ref) values (p_user, 'packs', p_packs, p_ref); end if;
  if p_item is not null then insert into grants (user_id, kind, item, ref) values (p_user, 'item', p_item, p_ref); end if;
  if p_starter then update wallets set starter_bought = true, updated_at = now() where user_id = p_user; end if;
  return given;
end $$;

-- Extends the Gate Pass to the end of the paid (or trial) period.
create or replace function public.extend_pass(p_user uuid, p_until timestamptz, p_trial boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into wallets (user_id) values (p_user) on conflict (user_id) do nothing;
  update wallets set pass_until = greatest(coalesce(pass_until, p_until), p_until),
         trial_used = trial_used or p_trial, updated_at = now()
   where user_id = p_user;
end $$;

-- Lock the server-only functions away from players.
revoke all on function public.grant_purchase(uuid,text,integer,text,integer,boolean,integer,text,boolean) from public, anon, authenticated;
revoke all on function public.extend_pass(uuid,timestamptz,boolean) from public, anon, authenticated;
revoke all on function public.month_spent(uuid) from public, anon, authenticated;
grant execute on function public.my_wallet(), public.set_age_group(text), public.spend_porta(integer,text),
  public.claim_grants(), public.my_month_spent() to authenticated;
