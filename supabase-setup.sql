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
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9','gruppe-10','gruppe-11','gruppe-12'
  )),
  progress jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Falls "groups" schon aus einer früheren Version existiert (9 statt 12
-- Gruppen), die CHECK-Bedingung auf 12 Gruppen erweitern.
alter table public.groups drop constraint if exists groups_id_check;
alter table public.groups add constraint groups_id_check check (id in (
  'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
  'gruppe-6','gruppe-7','gruppe-8','gruppe-9','gruppe-10','gruppe-11','gruppe-12'
));

insert into public.groups (id) values
  ('gruppe-1'),('gruppe-2'),('gruppe-3'),('gruppe-4'),('gruppe-5'),
  ('gruppe-6'),('gruppe-7'),('gruppe-8'),('gruppe-9'),
  ('gruppe-10'),('gruppe-11'),('gruppe-12')
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

-- Kapazität serverseitig durchsetzen (max. 9 pro Gruppe - jede Gruppe hat
-- 9 feste Mitglieder), damit zwei Geräte nicht gleichzeitig den letzten
-- Platz belegen können.
create or replace function public.enforce_group_capacity()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.participants where group_id = new.group_id) >= 9 then
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

-- Setzt den Fortschritt (Fallakten + Punkte) einer Gruppe komplett zurück -
-- fürs Admin-Panel, damit Testdurchläufe vor dem eigentlichen Event nicht
-- in der echten Rangliste hängen bleiben. Mitgliederliste/Anmeldung der
-- Gruppe bleibt davon unberührt.
drop function if exists public.reset_group_progress(text);

create or replace function public.reset_group_progress(p_group_id text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  update public.groups
  set progress = '{}'::jsonb,
      updated_at = now()
  where id = p_group_id
  returning progress;
$$;

grant execute on function public.reset_group_progress(text) to anon;

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
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9','gruppe-10','gruppe-11','gruppe-12','_global'
  )),
  stage_times jsonb not null default '{}'::jsonb,
  break_stages jsonb not null default '[]'::jsonb,
  stage_addresses jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.schedules drop constraint if exists schedules_id_check;
alter table public.schedules add constraint schedules_id_check check (id in (
  'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
  'gruppe-6','gruppe-7','gruppe-8','gruppe-9','gruppe-10','gruppe-11','gruppe-12','_global'
));

insert into public.schedules (id) values
  ('gruppe-1'),('gruppe-2'),('gruppe-3'),('gruppe-4'),('gruppe-5'),
  ('gruppe-6'),('gruppe-7'),('gruppe-8'),('gruppe-9'),
  ('gruppe-10'),('gruppe-11'),('gruppe-12'),('_global')
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

-- HINWEIS: group_questions wird von der aktuellen App-Version nicht mehr
-- genutzt (abgelöst durch station_templates weiter unten, wo Fragen direkt
-- an der Stations-Vorlage hängen). Bleibt hier nur stehen, damit ein
-- erneutes Ausführen dieses Skripts nicht fehlschlägt - kann gefahrlos
-- manuell gelöscht werden, ist aber auch harmlos, wenn sie bestehen bleibt.
--
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

-- Stations-Vorlagen (Amt-Pool) fürs Admin-Panel: Titel, Amt, Icon, Adresse
-- und 5 Fragen (je mit Optionen, richtiger Antwort, Punkten bei richtiger
-- Antwort und Erklärung) hängen jetzt direkt an der Vorlage statt an einer
-- festen Fallakten-Reihenfolge. Ohne Einträge hier nutzt die App die im
-- Code eingebauten 7 Standardvorlagen weiter (rein optional).
create table if not exists public.station_templates (
  id text primary key,
  title text not null,
  amt text not null,
  icon text not null default '🏛️',
  address text not null default '',
  questions jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.station_templates enable row level security;

drop policy if exists "station_templates public read" on public.station_templates;
create policy "station_templates public read"
  on public.station_templates for select
  using (true);

-- Kein direktes UPDATE/INSERT für anon - Schreiben läuft nur über die
-- save_station_template()-Funktion (SECURITY DEFINER), gleiches Prinzip
-- wie save_schedule() oben.
drop function if exists public.save_station_template(text, text, text, text, text, jsonb);

create or replace function public.save_station_template(
  p_id text,
  p_title text,
  p_amt text,
  p_icon text,
  p_address text,
  p_questions jsonb
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  insert into public.station_templates (id, title, amt, icon, address, questions, updated_at)
  values (p_id, p_title, p_amt, coalesce(p_icon, '🏛️'), coalesce(p_address, ''), p_questions, now())
  on conflict (id) do update
    set title = excluded.title,
        amt = excluded.amt,
        icon = excluded.icon,
        address = excluded.address,
        questions = excluded.questions,
        updated_at = now()
  returning to_jsonb(public.station_templates.*);
$$;

grant execute on function public.save_station_template(text, text, text, text, text, jsonb) to anon;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'station_templates'
  ) then
    alter publication supabase_realtime add table public.station_templates;
  end if;
end $$;

-- Pro-Gruppe-Route: welche 4 Stations-Vorlagen (und in welcher Reihenfolge)
-- eine Gruppe durchläuft. Ohne Eintrag nutzt die App automatisch die ersten
-- 4 verfügbaren Vorlagen (rein optional, damit die Rallye auch ohne jede
-- Routen-Pflege sofort spielbar ist).
create table if not exists public.group_routes (
  group_id text primary key check (group_id in (
    'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9','gruppe-10','gruppe-11','gruppe-12'
  )),
  template_ids jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.group_routes enable row level security;

drop policy if exists "group_routes public read" on public.group_routes;
create policy "group_routes public read"
  on public.group_routes for select
  using (true);

drop function if exists public.save_group_route(text, jsonb);

create or replace function public.save_group_route(p_group_id text, p_template_ids jsonb)
returns jsonb
language sql
security definer
set search_path = public
as $$
  insert into public.group_routes (group_id, template_ids, updated_at)
  values (p_group_id, p_template_ids, now())
  on conflict (group_id) do update
    set template_ids = excluded.template_ids,
        updated_at = now()
  returning to_jsonb(public.group_routes.*);
$$;

grant execute on function public.save_group_route(text, jsonb) to anon;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'group_routes'
  ) then
    alter publication supabase_realtime add table public.group_routes;
  end if;
end $$;

-- Gruppen-Passwörter: mit welchem Passwort sich eine Gruppe auf ihren
-- Geräten anmeldet. Ohne eigenen Eintrag nutzt die App weiterhin die
-- eingebauten Standard-Passwörter (rallye1..rallye12), damit die Rallye
-- auch ohne jede Admin-Pflege sofort spielbar ist.
create table if not exists public.group_passwords (
  group_id text primary key check (group_id in (
    'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9','gruppe-10','gruppe-11','gruppe-12'
  )),
  password text not null,
  updated_at timestamptz not null default now()
);

alter table public.group_passwords enable row level security;

drop policy if exists "group_passwords public read" on public.group_passwords;
create policy "group_passwords public read"
  on public.group_passwords for select
  using (true);

-- Kein direktes UPDATE/INSERT für anon - Schreiben läuft nur über die
-- save_group_password()-Funktion (SECURITY DEFINER), gleiches Prinzip wie
-- save_group_route() oben.
drop function if exists public.save_group_password(text, text);

create or replace function public.save_group_password(p_group_id text, p_password text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  insert into public.group_passwords (group_id, password, updated_at)
  values (p_group_id, p_password, now())
  on conflict (group_id) do update
    set password = excluded.password,
        updated_at = now()
  returning to_jsonb(public.group_passwords.*);
$$;

grant execute on function public.save_group_password(text, text) to anon;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'group_passwords'
  ) then
    alter publication supabase_realtime add table public.group_passwords;
  end if;
end $$;

-- Namensliste der Teammitglieder je Gruppe - rein organisatorisch fürs
-- Orga-Team (wer gehört zu welcher Gruppe), ohne Einfluss auf Anmeldung
-- oder Kapazität. Ohne Eintrag ist die Liste einfach leer.
create table if not exists public.group_members (
  group_id text primary key check (group_id in (
    'gruppe-1','gruppe-2','gruppe-3','gruppe-4','gruppe-5',
    'gruppe-6','gruppe-7','gruppe-8','gruppe-9','gruppe-10','gruppe-11','gruppe-12'
  )),
  names jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.group_members enable row level security;

drop policy if exists "group_members public read" on public.group_members;
create policy "group_members public read"
  on public.group_members for select
  using (true);

-- Kein direktes UPDATE/INSERT für anon - Schreiben läuft nur über die
-- save_group_members()-Funktion (SECURITY DEFINER), gleiches Prinzip wie
-- save_group_password() oben.
drop function if exists public.save_group_members(text, jsonb);

create or replace function public.save_group_members(p_group_id text, p_names jsonb)
returns jsonb
language sql
security definer
set search_path = public
as $$
  insert into public.group_members (group_id, names, updated_at)
  values (p_group_id, p_names, now())
  on conflict (group_id) do update
    set names = excluded.names,
        updated_at = now()
  returning to_jsonb(public.group_members.*);
$$;

grant execute on function public.save_group_members(text, jsonb) to anon;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'group_members'
  ) then
    alter publication supabase_realtime add table public.group_members;
  end if;
end $$;

-- Anonymes Feedback: EIN Formular (Singleton-Zeile 'main') mit einem
-- Fragenkatalog (je Frage 'choice' mit Optionen oder 'text' für Freitext)
-- und einer Stundenzahl, nach der das Feedback-Popup bei jedem Team
-- erscheint (gerechnet ab dem globalen Rallye-Start, siehe COUNTDOWN_TARGET
-- im HTML). feedback_responses speichert bewusst NUR die Antworten - es
-- gibt absichtlich keine Spalte für Gruppe, Gerät oder Teilnehmer:in, damit
-- Rückmeldungen strukturell anonym bleiben.
create table if not exists public.feedback_form (
  id text primary key default 'main',
  questions jsonb not null default '[]'::jsonb,
  trigger_hours numeric not null default 3,
  updated_at timestamptz not null default now()
);

insert into public.feedback_form (id) values ('main') on conflict (id) do nothing;

alter table public.feedback_form enable row level security;

drop policy if exists "feedback_form public read" on public.feedback_form;
create policy "feedback_form public read"
  on public.feedback_form for select
  using (true);

-- Kein direktes UPDATE für anon - Schreiben läuft nur über die
-- save_feedback_form()-Funktion (SECURITY DEFINER), gleiches Prinzip wie
-- save_schedule() oben.
drop function if exists public.save_feedback_form(jsonb, numeric);

create or replace function public.save_feedback_form(p_questions jsonb, p_trigger_hours numeric)
returns jsonb
language sql
security definer
set search_path = public
as $$
  insert into public.feedback_form (id, questions, trigger_hours, updated_at)
  values ('main', p_questions, p_trigger_hours, now())
  on conflict (id) do update
    set questions = excluded.questions,
        trigger_hours = excluded.trigger_hours,
        updated_at = now()
  returning to_jsonb(public.feedback_form.*);
$$;

grant execute on function public.save_feedback_form(jsonb, numeric) to anon;

create table if not exists public.feedback_responses (
  id uuid primary key default gen_random_uuid(),
  answers jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.feedback_responses enable row level security;

drop policy if exists "feedback_responses public read" on public.feedback_responses;
create policy "feedback_responses public read"
  on public.feedback_responses for select
  using (true);

-- Direktes INSERT für anon erlaubt (wie bei "participants" oben) - jede:r
-- kann eine anonyme Antwort abschicken, ohne dass eine Spalte existiert, die
-- Rückschlüsse auf Gruppe/Gerät zuließe.
drop policy if exists "feedback_responses public insert" on public.feedback_responses;
create policy "feedback_responses public insert"
  on public.feedback_responses for insert
  with check (true);

-- Verlauf gesendeter Durchsagen: der Realtime-Broadcast selbst (siehe
-- sendAnnouncement() im HTML) wird nirgends gespeichert und wäre für
-- Admins, die sich erst danach einloggen, verloren - diese Tabelle hält
-- die letzten Durchsagen fest, damit sie im Panel sichtbar bleiben.
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  text text not null,
  created_at timestamptz not null default now()
);

alter table public.announcements enable row level security;

drop policy if exists "announcements public read" on public.announcements;
create policy "announcements public read"
  on public.announcements for select
  using (true);

-- Direktes INSERT für anon erlaubt (wie bei "participants"/
-- "feedback_responses" oben) - der Broadcast, den diese Tabelle nur
-- protokolliert, ist ohnehin ungeschützt.
drop policy if exists "announcements public insert" on public.announcements;
create policy "announcements public insert"
  on public.announcements for insert
  with check (true);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'announcements'
  ) then
    alter publication supabase_realtime add table public.announcements;
  end if;
end $$;
