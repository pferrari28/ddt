-- =====================================================================
-- DDT · Documenti di trasporto · Installazione (10/11/2026)
--
-- Supabase → SQL Editor → New query → incolla tutto → Run.
-- Si può rieseguire senza problemi. Crea SOLO tabelle e funzioni che
-- iniziano con «ddt_»: non tocca registro lotti né magazzino.
--
-- Accessi: usa gli stessi utenti del registro lotti (stessa password).
-- Per cambiare chi può usare i DDT modifica l'elenco nella funzione
-- ddt_ok() qui sotto (e rieseguila).
-- =====================================================================

-- 1) chi può usare il programma ---------------------------------------
create or replace function public.ddt_ok()
returns boolean language sql stable security definer set search_path = public as
$$ select lower(coalesce(auth.jwt() ->> 'email', '')) in
          ('spedizioni@lotti.local', 'admin@lotti.local') $$;

create or replace function public.ddt_is_admin()
returns boolean language sql stable security definer set search_path = public as
$$ select lower(coalesce(auth.jwt() ->> 'email', '')) = 'admin@lotti.local' $$;

-- 2) tabelle -----------------------------------------------------------
create table if not exists public.ddt_destinatari (
  id uuid primary key default gen_random_uuid(),
  nome text not null,                 -- ragione sociale (per l'elenco)
  dati jsonb not null default '{}',   -- cessionario, destinazione, causale, copie...
  creato_il timestamptz not null default now(),
  aggiornato_il timestamptz not null default now()
);

create table if not exists public.ddt_contatori (
  anno int primary key,
  ultimo int not null default 0       -- ultimo numero già assegnato
);

create table if not exists public.ddt_config (
  chiave text primary key,
  valore jsonb not null
);
insert into public.ddt_config (chiave, valore) values ('copie', '1'::jsonb)
on conflict (chiave) do nothing;

create table if not exists public.ddt_bolle (
  id uuid primary key default gen_random_uuid(),
  anno int not null,
  numero int not null,
  data date not null,
  dest_id uuid,
  dest_nome text,
  causale text,
  totale_kg numeric,
  colli int,
  copie int not null default 1,
  dati jsonb not null,                -- copia completa del documento com'è stato stampato
  annullata boolean not null default false,
  annullata_il timestamptz,
  creato_da text,
  creato_il timestamptz not null default now(),
  unique (anno, numero)
);
create index if not exists ddt_bolle_data_idx on public.ddt_bolle (data desc, numero desc);

-- Righe tolte dall'elenco «Merce uscita» (solo Paolo). Il DDT non cambia.
create table if not exists public.ddt_merce_escluse (
  bolla_id uuid not null references public.ddt_bolle (id) on delete cascade,
  riga int not null,
  anno int not null,
  creato_il timestamptz not null default now(),
  primary key (bolla_id, riga)
);
create index if not exists ddt_merce_escluse_anno_idx on public.ddt_merce_escluse (anno);

-- Registro dei clienti sfridi (Padania, Rossi, Zanetti): una riga per consegna.
-- Le righe collegate a un DDT (bolla_id) si creano da sole; le altre sono manuali/storiche.
create table if not exists public.ddt_sfridi (
  id uuid primary key default gen_random_uuid(),
  cliente text not null check (cliente in ('padania', 'rossi', 'zanetti')),
  data date not null,
  numero int,                          -- numero del DDT (vuoto per le righe manuali)
  kg numeric,
  kg_expr text,                        -- formula scritta, es. =755+768
  consegnati int not null default 0,   -- bancali consegnati
  resi int not null default 0,         -- bancali resi
  nota text,
  bolla_id uuid unique references public.ddt_bolle (id) on delete set null,
  annullata boolean not null default false,
  creato_il timestamptz not null default now()
);
create index if not exists ddt_sfridi_cliente_idx on public.ddt_sfridi (cliente, data);

-- Aggiornamento leggero: ogni riga ricorda quando è stata toccata l'ultima volta,
-- così le pagine scaricano solo le novità invece di tutto l'archivio.
alter table public.ddt_bolle add column if not exists aggiornato_il timestamptz not null default now();
alter table public.ddt_sfridi add column if not exists aggiornato_il timestamptz not null default now();
create index if not exists ddt_bolle_agg_idx on public.ddt_bolle (anno, aggiornato_il);
create or replace function public.ddt_tocca() returns trigger language plpgsql as
$$ begin new.aggiornato_il := now(); return new; end $$;
drop trigger if exists ddt_bolle_tocca on public.ddt_bolle;
create trigger ddt_bolle_tocca before insert or update on public.ddt_bolle for each row execute function public.ddt_tocca();
drop trigger if exists ddt_sfridi_tocca on public.ddt_sfridi;
create trigger ddt_sfridi_tocca before insert or update on public.ddt_sfridi for each row execute function public.ddt_tocca();


-- Bozze: DDT salvati a metà (senza numero), da riprendere.
create table if not exists public.ddt_bozze (
  id uuid primary key default gen_random_uuid(),
  sfr text,                            -- vuoto = DDT generico; altrimenti padania / rossi / zanetti
  dati jsonb not null,
  etichetta text,
  creato_da text,
  aggiornato_il timestamptz not null default now()
);

-- Vettori e targhe: elenchi a tendina del modulo DDT.
create table if not exists public.ddt_vettori (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,           -- ditta (prima riga del campo vettore)
  riga2 text, riga3 text,              -- indirizzo; CAP città (provincia)
  creato_il timestamptz not null default now()
);
create table if not exists public.ddt_targhe (
  id uuid primary key default gen_random_uuid(),
  targa text not null unique,
  vettore text,                        -- nome del vettore a cui appartiene (facoltativo)
  creato_il timestamptz not null default now()
);

-- 3) permessi (RLS) ----------------------------------------------------
alter table public.ddt_destinatari enable row level security;
alter table public.ddt_contatori   enable row level security;
alter table public.ddt_config      enable row level security;
alter table public.ddt_bolle       enable row level security;
alter table public.ddt_merce_escluse enable row level security;
alter table public.ddt_sfridi enable row level security;
alter table public.ddt_bozze enable row level security;
alter table public.ddt_vettori enable row level security;
alter table public.ddt_targhe enable row level security;

drop policy if exists ddt_dest_all on public.ddt_destinatari;
create policy ddt_dest_all on public.ddt_destinatari for all to authenticated
  using (public.ddt_ok()) with check (public.ddt_ok());

drop policy if exists ddt_cont_sel on public.ddt_contatori;
create policy ddt_cont_sel on public.ddt_contatori for select to authenticated using (public.ddt_ok());

drop policy if exists ddt_conf_sel on public.ddt_config;
create policy ddt_conf_sel on public.ddt_config for select to authenticated using (public.ddt_ok());

drop policy if exists ddt_bolle_sel on public.ddt_bolle;
create policy ddt_bolle_sel on public.ddt_bolle for select to authenticated using (public.ddt_ok());
drop policy if exists ddt_escl_admin on public.ddt_merce_escluse;
create policy ddt_escl_admin on public.ddt_merce_escluse for all to authenticated
  using (public.ddt_is_admin()) with check (public.ddt_is_admin());

drop policy if exists ddt_sfr_sel on public.ddt_sfridi;
create policy ddt_sfr_sel on public.ddt_sfridi for select to authenticated using (public.ddt_ok());
drop policy if exists ddt_sfr_admin on public.ddt_sfridi;
create policy ddt_sfr_admin on public.ddt_sfridi for all to authenticated
  using (public.ddt_is_admin()) with check (public.ddt_is_admin());

drop policy if exists ddt_vettori_all on public.ddt_vettori;
create policy ddt_vettori_all on public.ddt_vettori for all to authenticated using (public.ddt_ok()) with check (public.ddt_ok());
drop policy if exists ddt_targhe_all on public.ddt_targhe;
create policy ddt_targhe_all on public.ddt_targhe for all to authenticated using (public.ddt_ok()) with check (public.ddt_ok());
drop policy if exists ddt_bozze_all on public.ddt_bozze;
create policy ddt_bozze_all on public.ddt_bozze for all to authenticated
  using (public.ddt_ok()) with check (public.ddt_ok());

-- le bolle si creano/annullano solo con le funzioni qui sotto (numero sempre univoco)

-- 4) funzioni ------------------------------------------------------------
-- Emette un DDT: assegna il numero successivo in modo atomico (anche con
-- più PC che premono «Salva e stampa» nello stesso istante) e salva.
create or replace function public.ddt_emetti(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
  v_data date := coalesce(nullif(p ->> 'data', '')::date, current_date);
  v_anno int := extract(year from v_data)::int;
  v_num int;
  v_row public.ddt_bolle;
begin
  if not public.ddt_ok() then raise exception 'Utente non abilitato ai DDT'; end if;

  insert into public.ddt_contatori (anno, ultimo) values (v_anno, 1)
  on conflict (anno) do update set ultimo = public.ddt_contatori.ultimo + 1
  returning ultimo into v_num;

  insert into public.ddt_bolle (anno, numero, data, dest_id, dest_nome, causale, totale_kg, colli, copie, dati, creato_da)
  values (v_anno, v_num, v_data,
          nullif(p ->> 'dest_id', '')::uuid,
          p -> 'ced' ->> 0,
          p ->> 'causale',
          nullif(p ->> 'peso_num', '')::numeric,
          nullif(p ->> 'colli', '')::int,
          greatest(coalesce(nullif(p ->> 'copie', '')::int, 1), 1),
          p,
          lower(auth.jwt() ->> 'email'))
  returning * into v_row;

  if coalesce(p ->> 'sfr', '') in ('padania', 'rossi', 'zanetti') then
    insert into public.ddt_sfridi (cliente, data, numero, kg, consegnati, resi, bolla_id)
    values (p ->> 'sfr', v_data, v_num, nullif(p ->> 'peso_num', '')::numeric,
            coalesce(nullif(p ->> 'bancali_cons', '')::int, 0), coalesce(nullif(p ->> 'bancali_resi', '')::int, 0), v_row.id);
  end if;

  return to_jsonb(v_row);
end $$;

-- Modifica un DDT già emesso: il numero e l'anno restano gli stessi.
create or replace function public.ddt_modifica(p_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
  v_old public.ddt_bolle;
  v_data date := coalesce(nullif(p ->> 'data', '')::date, current_date);
  v_row public.ddt_bolle;
begin
  if not public.ddt_ok() then raise exception 'Utente non abilitato ai DDT'; end if;
  select * into v_old from public.ddt_bolle where id = p_id;
  if not found then raise exception 'DDT non trovato'; end if;
  if extract(year from v_data)::int <> v_old.anno then
    raise exception 'La data deve restare nell''anno %, perché il numero appartiene a quell''anno', v_old.anno;
  end if;
  update public.ddt_bolle set
    data = v_data,
    dest_id = nullif(p ->> 'dest_id', '')::uuid,
    dest_nome = p -> 'ced' ->> 0,
    causale = p ->> 'causale',
    totale_kg = nullif(p ->> 'peso_num', '')::numeric,
    colli = nullif(p ->> 'colli', '')::int,
    copie = greatest(coalesce(nullif(p ->> 'copie', '')::int, 1), 1),
    dati = p
  where id = p_id returning * into v_row;
  delete from public.ddt_merce_escluse where bolla_id = p_id;   -- le righe potrebbero essere cambiate
  update public.ddt_sfridi set data = v_data, kg = nullif(p ->> 'peso_num', '')::numeric,
         consegnati = coalesce(nullif(p ->> 'bancali_cons', '')::int, 0), resi = coalesce(nullif(p ->> 'bancali_resi', '')::int, 0)
  where bolla_id = p_id;
  return to_jsonb(v_row);
end $$;

create or replace function public.ddt_annulla(p_id uuid, p_annulla boolean default true)
returns void language plpgsql security definer set search_path = public as
$$
begin
  if not public.ddt_ok() then raise exception 'Utente non abilitato ai DDT'; end if;
  update public.ddt_bolle set annullata = p_annulla,
         annullata_il = case when p_annulla then now() else null end
  where id = p_id;
  update public.ddt_sfridi set annullata = p_annulla where bolla_id = p_id;
end $$;

-- Solo Paolo: elimina DEFINITIVAMENTE un DDT (es. prove fatte prima della consegna).
-- Toglie anche la riga collegata nel registro sfridi. Se era l'ultimo numero emesso
-- dell'anno, il contatore torna indietro di uno (il numero si riutilizza).
create or replace function public.ddt_elimina(p_id uuid)
returns void language plpgsql security definer set search_path = public as
$$
declare b record;
begin
  if not public.ddt_is_admin() then raise exception 'Solo l''amministratore può eliminare un DDT'; end if;
  select anno, numero into b from public.ddt_bolle where id = p_id;
  if not found then return; end if;
  delete from public.ddt_sfridi where bolla_id = p_id;
  delete from public.ddt_bolle where id = p_id;
  update public.ddt_contatori
     set ultimo = greatest(b.numero - 1, coalesce((select max(numero) from public.ddt_bolle where anno = b.anno), 0))
   where anno = b.anno and ultimo = b.numero;
end $$;

-- Solo Paolo: decide da quale numero si riparte (es. l'ultimo DDT cartaceo
-- dell'anno era il 125 → imposta 125: il prossimo sarà il 126).
create or replace function public.ddt_imposta_ultimo(p_anno int, p_ultimo int)
returns void language plpgsql security definer set search_path = public as
$$
begin
  if not public.ddt_is_admin() then raise exception 'Solo Paolo può cambiare la numerazione'; end if;
  if p_ultimo < coalesce((select max(numero) from public.ddt_bolle where anno = p_anno), 0) then
    raise exception 'Esistono già DDT con numero più alto: non si può tornare indietro';
  end if;
  insert into public.ddt_contatori (anno, ultimo) values (p_anno, p_ultimo)
  on conflict (anno) do update set ultimo = excluded.ultimo;
end $$;

create or replace function public.ddt_imposta_copie(p_copie int)
returns void language plpgsql security definer set search_path = public as
$$
begin
  if not public.ddt_is_admin() then raise exception 'Solo Paolo può cambiare le copie'; end if;
  insert into public.ddt_config (chiave, valore) values ('copie', to_jsonb(greatest(p_copie, 1)))
  on conflict (chiave) do update set valore = excluded.valore;
end $$;

grant execute on function public.ddt_ok(), public.ddt_is_admin(),
  public.ddt_emetti(jsonb), public.ddt_modifica(uuid, jsonb), public.ddt_annulla(uuid, boolean),
  public.ddt_imposta_ultimo(int, int), public.ddt_imposta_copie(int), public.ddt_elimina(uuid) to authenticated;
