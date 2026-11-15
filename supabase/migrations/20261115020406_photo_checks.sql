-- Hololoco, part 8: the automatic photo check.
--
-- Photos no longer need a person. The scan-photo Edge Function checks every
-- image a photo upload will show (the photo, its pin thumbnail, and the picture
-- inside its framed 3D version) with Google Cloud Vision SafeSearch, and checks
-- the framed model is the kind the website makes: a few triangles, no outside
-- links. A clean photo is published (its files copied to the public bucket) and
-- the drops waiting only for it go live. A flagged one waits in the review queue
-- with what was flagged. If the check can't run, a person checks the photo, as
-- before. 3D models still always wait for a person.
--
-- Set up once per project, outside this migration: deploy supabase/functions/scan-photo
-- (no JWT check; it trusts nothing but the upload's id) and give it a
-- GOOGLE_VISION_API_KEY secret. The project_url vault secret from part 5 says where to send.

alter table public.assets
  add column scan_state text check (scan_state in ('queued', 'running', 'done', 'failed')),
  add column scan jsonb,
  add column scanned_at timestamptz;

-- Every new photo is queued for the check, however it was added. Nobody can set these themselves.
create function public.assets_scan_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.scan_state := case when new.kind = 'photo' then 'queued' end;
  new.scan := null;
  new.scanned_at := null;
  return new;
end;
$$;

revoke execute on function public.assets_scan_before_insert() from public, anon, authenticated;

create trigger assets_scan_before_insert
  before insert on public.assets
  for each row execute function public.assets_scan_before_insert();

-- Fire and forget, like send_check: a problem here never stops an upload.
create function private.send_photo_scan(p_asset uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
begin
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'project_url';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url := rtrim(v_url, '/') || '/functions/v1/scan-photo',
    body := jsonb_build_object('assetId', p_asset),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'send_photo_scan(%): %', p_asset, sqlerrm;
end;
$$;

revoke execute on function private.send_photo_scan(uuid) from public, anon, authenticated;

create function public.assets_request_scan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.send_photo_scan(new.id);
  return null;
end;
$$;

revoke execute on function public.assets_request_scan() from public, anon, authenticated;

create trigger assets_scan_after_insert
  after insert on public.assets
  for each row when (new.scan_state = 'queued')
  execute function public.assets_request_scan();

-- ---------------------------------------------------------------------------
-- What the Edge Function calls (over its direct database connection).
-- ---------------------------------------------------------------------------

-- Claim a queued photo and say where its files are, or null if it isn't waiting.
create function private.claim_photo_scan(p_asset uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.assets;
begin
  select * into a from public.assets x
  where x.id = p_asset and x.kind = 'photo' and x.scan_state = 'queued'
  for update skip locked;
  if a.id is null then
    return null;
  end if;
  update public.assets x set scan_state = 'running', scanned_at = now() where x.id = a.id;
  return jsonb_build_object('assetId', a.id, 'model', a.model_path, 'thumbnail', a.thumbnail_path, 'photo', a.photo_path);
end;
$$;

-- Record the check. A clean photo whose files have been copied to the public
-- bucket is published, and the drops waiting only for it go live: their account
-- is in good standing, nobody has reported them, a person hasn't turned them
-- down, and the automatic drop check (if on) has finished. Returns what happened:
-- published, held, failed (the copies are missing) or ignored.
create function private.finish_photo_scan(p_asset uuid, p_result jsonb, p_clean boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.assets;
  v_model text;
  v_thumbnail text;
  v_photo text;
begin
  select * into a from public.assets x where x.id = p_asset for update;
  if a.id is null or a.scan_state is distinct from 'running' then
    return 'ignored';
  end if;

  if not p_clean or a.status = 'rejected' then
    update public.assets x set scan_state = 'done', scan = p_result, scanned_at = now() where x.id = a.id;
    return case when p_clean then 'ignored' else 'held' end;
  end if;

  v_model := a.id::text || '/model.glb';
  v_thumbnail := a.id::text || '/thumbnail.png';
  v_photo := a.id::text || '/photo.jpg';
  if not exists (select 1 from storage.objects o where o.bucket_id = 'drop-assets' and o.name = v_model)
     or not exists (select 1 from storage.objects o where o.bucket_id = 'drop-assets' and o.name = v_thumbnail)
     or not exists (select 1 from storage.objects o where o.bucket_id = 'drop-assets' and o.name = v_photo) then
    update public.assets x set scan_state = 'failed', scan = p_result || '{"error": "not_copied"}'::jsonb, scanned_at = now()
    where x.id = a.id;
    return 'failed';
  end if;

  update public.assets x set
    status = 'approved',
    public_model_path = v_model,
    public_thumbnail_path = v_thumbnail,
    public_photo_path = v_photo,
    scan_state = 'done',
    scan = p_result,
    scanned_at = now()
  where x.id = a.id;

  perform set_config('hololoco.system', 'on', true);
  with approved as (
    update public.drops d set review = 'approved', review_reason = null
    where d.asset_id = a.id
      and d.review = 'pending'
      and public.account_standing(d.owner_id) = 'good'
      and not exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open')
      and not exists (select 1 from public.moderation_events e
                      where e.drop_id = d.id and e.action = 'reject' and not e.automatic)
      and (d.check_state is null or d.check_state in ('done', 'failed'))
    returning d.id, d.title
  )
  insert into public.moderation_events (drop_id, drop_title, actor_id, action, reason, automatic)
  select approved.id, approved.title, null, 'approve', 'Automatic photo check', true from approved;
  perform set_config('hololoco.system', '', true);

  return 'published';
end;
$$;

-- The check couldn't run: a person checks the photo instead.
create function private.fail_photo_scan(p_asset uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.assets x set scan_state = 'failed', scan = jsonb_build_object('error', left(p_error, 300)), scanned_at = now()
  where x.id = p_asset and x.scan_state = 'running';
end;
$$;

revoke execute on function private.claim_photo_scan(uuid) from public, anon, authenticated;
revoke execute on function private.finish_photo_scan(uuid, jsonb, boolean) from public, anon, authenticated;
revoke execute on function private.fail_photo_scan(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Owners see that their photo is being checked; staff see what was flagged.
-- ---------------------------------------------------------------------------

create or replace function public.my_drops()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d) || jsonb_build_object(
    'hiddenForReport', d.review = 'pending'
      and exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open'),
    'assetFiles', public.drop_asset_files(d),
    'check', public.drop_check_json(d, false),
    'photoCheck', (select a.scan_state from public.assets a where a.id = d.asset_id and a.kind = 'photo'),
    'quest', (select jsonb_build_object('id', q.id, 'name', q.name, 'position', s.position, 'stageCount', q.stage_count)
              from public.quest_stages s join public.quests q on q.id = s.quest_id
              where s.drop_id = d.id and q.status = 'active'
              limit 1))
  from public.drops d
  where d.owner_id = (select auth.uid())
  order by d.created_at desc;
$$;

-- A photo still being checked (for up to five minutes) isn't waiting for a person yet.
create or replace function public.review_queue()
returns setof jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  return query
    select public.drop_to_json(d) || jsonb_build_object(
      'ownerApproved', (select count(*) from public.drops x where x.owner_id = d.owner_id and x.review = 'approved'),
      'ownerRejected', (select count(*) from public.drops x where x.owner_id = d.owner_id and x.review = 'rejected'),
      'ownerSince', (select p.created_at from public.profiles p where p.id = d.owner_id),
      'ownerStrikes', (select p.strikes from public.profiles p where p.id = d.owner_id),
      'ownerStanding', public.account_standing(d.owner_id),
      'assetFiles', public.drop_asset_files(d),
      'check', public.drop_check_json(d, true),
      'photoCheck', (select jsonb_build_object('state', a.scan_state, 'result', a.scan)
                     from public.assets a where a.id = d.asset_id and a.kind = 'photo'))
    from public.drops d
    where d.review = 'pending'
      and d.check_state is distinct from 'queued'
      and d.check_state is distinct from 'running'
      and d.check_state is distinct from 'retry'
      and not exists (select 1 from public.assets a
                      where a.id = d.asset_id and a.scan_state in ('queued', 'running')
                        and a.created_at > now() - interval '5 minutes')
      and not exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open')
    order by d.created_at asc
    limit 200;
end;
$$;
