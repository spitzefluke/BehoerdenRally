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

-- Kapazität serverseitig durchsetzen (max. 5 pro Gruppe - jede Gruppe hat
-- 5 feste Mitglieder), damit zwei Geräte nicht gleichzeitig den letzten
-- Platz belegen können.
create or replace function public.enforce_group_capacity()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.participants where group_id = new.group_id) >= 5 then
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
-- p_points: wie viele der 5 Fragen dieser Station richtig beantwortet
-- wurden (Punkte für die Rangliste); wird zusammen mit "done" gespeichert,
-- damit jede Station ihre tatsächlich erzielte Punktzahl behält.
drop function if exists public.complete_stage(text, text);

create or replace function public.complete_stage(p_group_id text, p_stage_id text, p_points integer)
returns jsonb
language sql
security definer
set search_path = public
as $$
  update public.groups
  set progress = progress || jsonb_build_object(p_stage_id, jsonb_build_object('done', true, 'points', p_points)),
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
grant execute on function public.complete_stage(text, text, integer) to anon;

-- Realtime aktivieren, damit alle Geräte Änderungen sofort sehen.
-- (in ein DO-Block verpackt, weil "ALTER PUBLICATION ... ADD TABLE" beim
-- erneuten Ausführen sonst mit "already member of publication" fehlschlägt
-- und dabei das gesamte Skript inkl. der obigen Funktions-Änderung
-- zurückrollt)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'groups'
  ) then
    alter publication supabase_realtime add table public.groups;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'participants'
  ) then
    alter publication supabase_realtime add table public.participants;
  end if;
end $$;

-- Zeitpläne fürs Admin-Panel: pro Gruppe optionale Ankunftszeiten je
-- Fallakte (stage_times), welche Übergänge davon Pausen statt Fahrten sind
-- (break_stages), sowie eine gemeinsame Zeile '_global' mit den Stations-
-- Adressen (stage_addresses), die für alle Gruppen gleich sind. Ist für
-- eine Gruppe kein stage_times-Eintrag gesetzt, verhält sich die App wie
-- ohne Zeitplan (keine Sperre) - diese Tabelle ist rein optional.
create table if not exists public.schedules (
  id text primary key check (id in (
    'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9','_global'
  )),
  stage_times jsonb not null default '{}'::jsonb,
  break_stages jsonb not null default '[]'::jsonb,
  stage_addresses jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.schedules (id) values
  ('gruppe-1'),('gruppe-2'),('gruppe-3'),('gruppe-4'),('gruppe-5'),
  ('gruppe-6'),('gruppe-7'),('gruppe-8'),('gruppe-9'),('_global')
on conflict (id) do nothing;

alter table public.schedules enable row level security;

drop policy if exists "schedules public read" on public.schedules;
create policy "schedules public read"
  on public.schedules for select
  using (true);

-- Kein direktes UPDATE für anon - Schreiben läuft nur über die
-- save_schedule()-Funktion (SECURITY DEFINER), gleiches Prinzip wie
-- complete_stage() oben. Das Admin-Panel selbst ist nur durch ein
-- einfaches Passwort im Browser geschützt (kein echtes Server-Login) -
-- für ein einmaliges Event unkritisch, siehe supabase-setup.sql-Hinweis
-- oben zum generellen Sicherheitsmodell dieser App.
drop function if exists public.save_schedule(text, jsonb, jsonb, jsonb);

create or replace function public.save_schedule(
  p_id text,
  p_stage_times jsonb,
  p_break_stages jsonb,
  p_stage_addresses jsonb
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  insert into public.schedules (id, stage_times, break_stages, stage_addresses, updated_at)
  values (
    p_id,
    coalesce(p_stage_times, '{}'::jsonb),
    coalesce(p_break_stages, '[]'::jsonb),
    coalesce(p_stage_addresses, '{}'::jsonb),
    now()
  )
  on conflict (id) do update
    set stage_times = coalesce(p_stage_times, public.schedules.stage_times),
        break_stages = coalesce(p_break_stages, public.schedules.break_stages),
        stage_addresses = coalesce(p_stage_addresses, public.schedules.stage_addresses),
        updated_at = now()
  returning to_jsonb(public.schedules.*);
$$;

grant execute on function public.save_schedule(text, jsonb, jsonb, jsonb) to anon;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'schedules'
  ) then
    alter publication supabase_realtime add table public.schedules;
  end if;
end $$;

-- Eigene Quizfragen je Gruppe/Station fürs Admin-Panel. group_id ist eine
-- echte Gruppe ODER '_default' für den gemeinsamen Standard-Fragensatz, der
-- für alle Gruppen ohne eigene Fragen gilt. Ist für eine Gruppe+Station gar
-- nichts hinterlegt (weder eigene Fragen noch '_default'), nutzt die App die
-- im Code eingebauten Standardfragen weiter - auch diese Tabelle ist rein
-- optional.
create table if not exists public.group_questions (
  group_id text not null check (group_id in (
    'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9','_default'
  )),
  stage_id text not null,
  questions jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (group_id, stage_id)
);

alter table public.group_questions enable row level security;

drop policy if exists "group_questions public read" on public.group_questions;
create policy "group_questions public read"
  on public.group_questions for select
  using (true);

-- Kein direktes UPDATE für anon - Schreiben läuft nur über die
-- save_group_questions()-Funktion (SECURITY DEFINER), gleiches Prinzip wie
-- save_schedule() oben.
drop function if exists public.save_group_questions(text, text, jsonb);

create or replace function public.save_group_questions(p_group_id text, p_stage_id text, p_questions jsonb)
returns jsonb
language sql
security definer
set search_path = public
as $$
  insert into public.group_questions (group_id, stage_id, questions, updated_at)
  values (p_group_id, p_stage_id, p_questions, now())
  on conflict (group_id, stage_id) do update
    set questions = excluded.questions,
        updated_at = now()
  returning to_jsonb(public.group_questions.*);
$$;

grant execute on function public.save_group_questions(text, text, jsonb) to anon;
