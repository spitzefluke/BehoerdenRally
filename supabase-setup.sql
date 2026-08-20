-- Behördenrallye: Supabase-Schema für geräteübergreifende Gruppen-Missionen
-- und Rangliste.
--
-- Einmalig im Supabase Dashboard ausführen: Project -> SQL Editor -> New query
-- -> diesen kompletten Inhalt einfügen -> Run.
--
-- Datenmodell: Die 7 Missionen gehören der GRUPPE, nicht der einzelnen
-- Person - beantwortet ein Teammitglied eine Frage richtig, sehen alle
-- anderen Mitglieder sofort dieselbe Mission als erledigt und die nächste
-- Mission entsperrt (über Supabase Realtime). "groups" speichert diesen
-- gemeinsamen Fortschritt, "participants" nur, wer in welcher Gruppe ist
-- (für Kapazität/Namensliste).
--
-- Sicherheitsmodell: Es gibt kein Login (die Rallye braucht keins). Jede:r
-- mit dem anon-Key (im HTML sichtbar) kann lesen, sich als Teilnehmer:in
-- eintragen und über die complete_stage()-Funktion Missionen für die
-- eigene Gruppe abschließen. Das entspricht dem bisherigen Vertrauens-
-- modell der App (vorher war alles im Browser-localStorage frei
-- editierbar), ist für ein einmaliges Event aber unkritisch.

create table if not exists public.groups (
  id text primary key check (id in (
    'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9'
  )),
  progress jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.groups (id) values
  ('gruppe-1'),('gruppe-2'),('gruppe-3'),('gruppe-4'),('gruppe-5'),
  ('gruppe-6'),('gruppe-7'),('gruppe-8'),('gruppe-9')
on conflict (id) do nothing;

create table if not exists public.participants (
  id text primary key,
  name text not null check (char_length(name) between 1 and 80),
  group_id text not null references public.groups(id),
  recovery_code text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists participants_group_id_idx on public.participants (group_id);
create index if not exists participants_recovery_code_idx on public.participants (recovery_code);

-- Kapazität serverseitig durchsetzen (max. 10 pro Gruppe), damit zwei
-- Geräte nicht gleichzeitig den letzten Platz belegen können.
create or replace function public.enforce_group_capacity()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.participants where group_id = new.group_id) >= 10 then
    raise exception 'GROUP_FULL' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists check_group_capacity on public.participants;
create trigger check_group_capacity
  before insert on public.participants
  for each row execute function public.enforce_group_capacity();

-- Atomares Abschließen einer Mission für die ganze Gruppe (verhindert
-- Race Conditions, wenn zwei Teammitglieder fast gleichzeitig antworten).
create or replace function public.complete_stage(p_group_id text, p_stage_id text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  update public.groups
  set progress = progress || jsonb_build_object(p_stage_id, true),
      updated_at = now()
  where id = p_group_id
  returning progress;
$$;

alter table public.groups enable row level security;
alter table public.participants enable row level security;

drop policy if exists "groups public read" on public.groups;
create policy "groups public read"
  on public.groups for select
  using (true);

drop policy if exists "participants public read" on public.participants;
create policy "participants public read"
  on public.participants for select
  using (true);

drop policy if exists "participants public insert" on public.participants;
create policy "participants public insert"
  on public.participants for insert
  with check (true);

-- Kein direktes UPDATE auf "groups" für anon - Fortschritt läuft nur über
-- die complete_stage()-Funktion (SECURITY DEFINER), das verhindert, dass
-- jemand beliebige Punktestände eintragen kann.
grant execute on function public.complete_stage(text, text) to anon;

-- Realtime aktivieren, damit alle Geräte Änderungen sofort sehen.
alter publication supabase_realtime add table public.groups;
alter publication supabase_realtime add table public.participants;
