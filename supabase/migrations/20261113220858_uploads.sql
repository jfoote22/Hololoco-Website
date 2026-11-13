-- Hololoco, part 4: photo and 3D model uploads (Phase 3).
--
-- People's browsers turn a photo or a GLB/FBX model into a small GLB (simplified
-- to a triangle budget, textures capped) plus a thumbnail, and upload those to a
-- private bucket in their own folder. A drop that uses an upload always waits
-- for review. Staff look at the actual files, and approving copies them to a
-- public bucket the map reads from; until then nobody else can fetch them.

-- ---------------------------------------------------------------------------
-- Buckets. Size and file types are enforced by Supabase Storage itself.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('uploads', 'uploads', false, 8388608, array['model/gltf-binary', 'image/png', 'image/jpeg']),
  ('drop-assets', 'drop-assets', true, 8388608, array['model/gltf-binary', 'image/png', 'image/jpeg'])
on conflict (id) do nothing;

create policy "People upload into their own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "People read their own uploads; staff read all" on storage.objects
  for select to authenticated
  using (bucket_id = 'uploads' and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.is_staff)));

create policy "People delete their own uploads" on storage.objects
  for delete to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Only staff put files in the public bucket (when approving) or take them out.
create policy "Staff publish approved files" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'drop-assets'
              and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.is_staff));

create policy "Staff remove published files" on storage.objects
  for delete to authenticated
  using (bucket_id = 'drop-assets'
         and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.is_staff));

-- ---------------------------------------------------------------------------
-- Assets: one per uploaded photo or model.
-- ---------------------------------------------------------------------------

create table public.assets (
  id uuid primary key,
  owner_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('photo', 'model')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  -- What the person chose, for reviewers.
  source_name text check (source_name is null or char_length(source_name) <= 200),
  source_format text not null check (source_format in ('glb', 'fbx', 'jpeg', 'png', 'webp', 'heic', 'other')),
  -- What the browser reported after simplifying. Reviewers' browsers count again.
  triangles integer check (triangles is null or triangles between 1 and 10000),
  -- Files in the private uploads bucket.
  model_path text not null,
  thumbnail_path text not null,
  photo_path text,
  -- Copies in the public drop-assets bucket, made when staff approve.
  public_model_path text,
  public_thumbnail_path text,
  public_photo_path text,
  created_at timestamptz not null default now(),

  constraint files_in_own_folder check (
    model_path = owner_id::text || '/' || id::text || '/model.glb'
    and thumbnail_path = owner_id::text || '/' || id::text || '/thumbnail.png'
    and (photo_path is null or photo_path = owner_id::text || '/' || id::text || '/photo.jpg')),
  constraint photos_have_a_photo check ((kind = 'photo') = (photo_path is not null))
);

create index assets_owner_idx on public.assets (owner_id, created_at desc);

alter table public.assets enable row level security;

create policy "Owners read their uploads" on public.assets
  for select to authenticated using (owner_id = (select auth.uid()));

create policy "Owners add uploads" on public.assets
  for insert to authenticated with check (owner_id = (select auth.uid()));

create policy "Owners delete their uploads" on public.assets
  for delete to authenticated using (owner_id = (select auth.uid()));

revoke all on table public.assets from anon, authenticated;
grant select, delete on table public.assets to authenticated;
grant insert (id, kind, source_name, source_format, triangles, model_path, thumbnail_path, photo_path)
  on table public.assets to authenticated;

-- New uploads: their files must already be in the person's folder, and there's a daily limit.
create function public.assets_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null or coalesce(current_setting('hololoco.system', true), '') = 'on' then
    return new;
  end if;

  new.owner_id := me;
  new.status := 'pending';
  new.public_model_path := null;
  new.public_thumbnail_path := null;
  new.public_photo_path := null;
  new.created_at := now();

  if not exists (select 1 from storage.objects o
                 where o.bucket_id = 'uploads' and o.name = new.model_path)
     or not exists (select 1 from storage.objects o
                    where o.bucket_id = 'uploads' and o.name = new.thumbnail_path)
     or (new.photo_path is not null and not exists (select 1 from storage.objects o
                                                    where o.bucket_id = 'uploads' and o.name = new.photo_path)) then
    raise exception 'upload_missing' using errcode = 'P0001';
  end if;

  if not public.is_staff()
     and (select count(*) from public.assets a where a.owner_id = me and a.created_at > now() - interval '1 day') >= 10 then
    raise exception 'limit_uploads' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke execute on function public.assets_before_insert() from public, anon, authenticated;

create trigger assets_before_insert
  before insert on public.assets
  for each row execute function public.assets_before_insert();

-- ---------------------------------------------------------------------------
-- Drops can use an upload instead of a ready-made object.
-- ---------------------------------------------------------------------------

alter table public.drops alter column object_id drop not null;
-- No action (not restrict): an account and its drops and uploads can be deleted together.
alter table public.drops add column asset_id uuid references public.assets (id);
alter table public.drops add constraint one_look check (num_nonnulls(object_id, asset_id) = 1);
create index drops_asset_idx on public.drops (asset_id);

grant insert (asset_id) on table public.drops to authenticated;
grant update (asset_id) on table public.drops to authenticated;

create or replace function public.drops_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  staff boolean := public.is_staff();
  profile public.profiles;
  asset public.assets;
  check_crowding boolean;
begin
  -- No signed-in user means the service role or the SQL editor, and
  -- hololoco.system means one of the database's own functions: both trusted.
  if me is null or coalesce(current_setting('hololoco.system', true), '') = 'on' then
    new.updated_at := now();
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.owner_id := me;
    new.created_at := now();
    new.paused := false;
    new.review_reason := null;

    select * into profile from public.profiles where id = me;
    if profile.display_name is null or profile.adult_confirmed_at is null then
      raise exception 'profile_incomplete' using errcode = 'P0001';
    end if;

    if not staff then
      if (select count(*) from public.drops d where d.owner_id = me and d.review <> 'rejected') >= 10 then
        raise exception 'limit_total' using errcode = 'P0001';
      end if;
      if (select count(*) from public.drops d
          where d.owner_id = me and d.created_at > now() - interval '1 day') >= 5 then
        raise exception 'limit_daily' using errcode = 'P0001';
      end if;
    end if;

    -- An account's drops are reviewed until one has been approved.
    new.review := case
      when staff or exists (select 1 from public.drops d where d.owner_id = me and d.review = 'approved')
        then 'approved'
      else 'pending'
    end;
  else
    if new.id <> old.id or new.owner_id <> old.owner_id or new.created_at <> old.created_at then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
    if not staff and (new.review <> old.review or new.review_reason is distinct from old.review_reason) then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
    -- Editing a drop that wasn't approved sends it back for review.
    if not staff and old.review = 'rejected' then
      new.review := 'pending';
      new.review_reason := null;
    end if;
  end if;

  -- An upload must be the person's own and not turned down, and a drop that
  -- uses one waits for review until the upload is approved, staff included.
  if new.asset_id is not null and (tg_op = 'INSERT' or new.asset_id is distinct from old.asset_id) then
    select * into asset from public.assets a where a.id = new.asset_id;
    if asset.id is null or asset.owner_id <> me then
      raise exception 'asset_not_found' using errcode = 'P0001';
    end if;
    if asset.status = 'rejected' then
      raise exception 'asset_rejected' using errcode = 'P0001';
    end if;
    if asset.status <> 'approved' then
      new.review := 'pending';
      new.review_reason := null;
    end if;
  end if;

  -- Crowding: only public drops count, and only when a public drop appears or moves.
  if tg_op = 'INSERT' then
    check_crowding := new.audience = 'everyone';
  else
    check_crowding := new.audience = 'everyone'
      and (new.lat <> old.lat or new.lng <> old.lng or old.audience <> 'everyone');
  end if;

  if check_crowding and not staff then
    if (select count(*) from public.drops d
        where d.id <> new.id
          and d.audience = 'everyone'
          and d.review = 'approved'
          and not d.paused
          and extensions.st_dwithin(
                d.geom::extensions.geography,
                extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography,
                100)) >= 20 then
      raise exception 'limit_crowded' using errcode = 'P0001';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- Saving a drop now takes either a ready-made object or an upload.
create or replace function public.save_drop(payload jsonb)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id text := nullif(payload ->> 'id', '');
  v_tz text := payload ->> 'timeZone';
  v_timing text := payload -> 'timing' ->> 'kind';
  v_blocks jsonb := payload -> 'timing' -> 'blocks';
  v_object text := nullif(payload ->> 'objectId', '');
  v_asset uuid := nullif(payload ->> 'assetId', '')::uuid;
  v_start timestamptz;
  v_end timestamptz;
begin
  if not public.is_time_zone(v_tz) then
    raise exception 'bad_time_zone' using errcode = 'P0001';
  end if;

  if v_timing = 'once' then
    -- Local wall-clock times in the drop's zone.
    v_start := ((payload -> 'timing' ->> 'start')::timestamp) at time zone v_tz;
    v_end := ((payload -> 'timing' ->> 'end')::timestamp) at time zone v_tz;
  elsif v_timing = 'weekly' then
    if jsonb_typeof(v_blocks) <> 'array' or jsonb_array_length(v_blocks) = 0 then
      raise exception 'schedule_empty' using errcode = 'P0001';
    end if;
    if jsonb_array_length(v_blocks) > 7 then
      raise exception 'schedule_too_long' using errcode = 'P0001';
    end if;
  end if;

  if v_id is null then
    insert into public.drops (type, title, description, object_id, asset_id, lat, lng, height, size, turn,
                              time_zone, timing, starts_at, ends_at, audience)
    values (payload ->> 'type', btrim(payload ->> 'title'), btrim(coalesce(payload ->> 'description', '')),
            v_object, v_asset,
            (payload -> 'placement' ->> 'lat')::double precision,
            (payload -> 'placement' ->> 'lng')::double precision,
            (payload -> 'placement' ->> 'height')::real,
            (payload -> 'placement' ->> 'size')::real,
            (payload -> 'placement' ->> 'turn')::real,
            v_tz, v_timing, v_start, v_end, payload ->> 'audience')
    returning id into v_id;
  else
    update public.drops set
      type = payload ->> 'type',
      title = btrim(payload ->> 'title'),
      description = btrim(coalesce(payload ->> 'description', '')),
      object_id = v_object,
      asset_id = v_asset,
      lat = (payload -> 'placement' ->> 'lat')::double precision,
      lng = (payload -> 'placement' ->> 'lng')::double precision,
      height = (payload -> 'placement' ->> 'height')::real,
      size = (payload -> 'placement' ->> 'size')::real,
      turn = (payload -> 'placement' ->> 'turn')::real,
      time_zone = v_tz,
      timing = v_timing,
      starts_at = v_start,
      ends_at = v_end,
      audience = payload ->> 'audience'
    where id = v_id
    returning id into v_id;

    if v_id is null then
      raise exception 'not_found' using errcode = 'P0001';
    end if;

    delete from public.schedule_blocks where drop_id = v_id;
  end if;

  if v_timing = 'weekly' then
    insert into public.schedule_blocks (drop_id, days, start_time, end_time)
    select v_id,
           array(select (x)::smallint from jsonb_array_elements_text(b -> 'days') x),
           (b ->> 'start')::time,
           (b ->> 'end')::time
    from jsonb_array_elements(v_blocks) b;
  end if;

  return v_id;
end;
$$;

-- The drop's JSON, now with its upload's public files (only set once approved).
create or replace function public.drop_to_json(d public.drops)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', d.id,
    'type', d.type,
    'title', d.title,
    'description', d.description,
    'objectId', d.object_id,
    'asset', (select jsonb_build_object(
                'id', a.id, 'kind', a.kind, 'status', a.status,
                'model', a.public_model_path, 'thumbnail', a.public_thumbnail_path, 'photo', a.public_photo_path)
              from public.assets a where a.id = d.asset_id),
    'placement', jsonb_build_object('lat', d.lat, 'lng', d.lng, 'height', d.height, 'size', d.size, 'turn', d.turn),
    'timeZone', d.time_zone,
    'timing', case d.timing
      when 'always' then jsonb_build_object('kind', 'always')
      when 'once' then jsonb_build_object(
        'kind', 'once',
        'start', to_char(d.starts_at at time zone d.time_zone, 'YYYY-MM-DD"T"HH24:MI'),
        'end', to_char(d.ends_at at time zone d.time_zone, 'YYYY-MM-DD"T"HH24:MI'))
      else jsonb_build_object(
        'kind', 'weekly',
        'blocks', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'days', to_jsonb(b.days),
                   'start', to_char(b.start_time, 'HH24:MI'),
                   'end', to_char(b.end_time, 'HH24:MI')) order by b.id)
          from public.schedule_blocks b where b.drop_id = d.id), '[]'::jsonb))
    end,
    'audience', d.audience,
    'owner', (select jsonb_build_object('name', coalesce(p.display_name, 'Someone'), 'kind', p.kind, 'verified', false)
              from public.profiles p where p.id = d.owner_id),
    'review', d.review,
    'reviewReason', d.review_reason,
    'paused', d.paused,
    'openNow', public.drop_is_open(d),
    'createdAt', d.created_at
  );
$$;

-- The private files of a drop's upload, for its owner and for staff only.
create function public.drop_asset_files(d public.drops)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('model', a.model_path, 'thumbnail', a.thumbnail_path, 'photo', a.photo_path,
                            'triangles', a.triangles, 'sourceName', a.source_name, 'sourceFormat', a.source_format)
  from public.assets a where a.id = d.asset_id;
$$;

revoke execute on function public.drop_asset_files(public.drops) from public, anon, authenticated;

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
    'assetFiles', public.drop_asset_files(d))
  from public.drops d
  where d.owner_id = (select auth.uid())
  order by d.created_at desc;
$$;

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
      'assetFiles', public.drop_asset_files(d))
    from public.drops d
    where d.review = 'pending'
      and not exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open')
    order by d.created_at asc
    limit 200;
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff: publishing an upload, and decisions that respect uploads.
-- ---------------------------------------------------------------------------

-- After a reviewer's browser has copied the files to the public bucket (under
-- the upload's id, so the owner's id never appears in a public address), mark
-- the upload approved.
create function public.publish_asset(asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.assets;
  v_model text;
  v_thumbnail text;
  v_photo text;
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  select * into v from public.assets a where a.id = publish_asset.asset_id;
  if v.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;

  v_model := v.id::text || '/model.glb';
  v_thumbnail := v.id::text || '/thumbnail.png';
  v_photo := case when v.kind = 'photo' then v.id::text || '/photo.jpg' end;

  if not exists (select 1 from storage.objects o where o.bucket_id = 'drop-assets' and o.name = v_model)
     or not exists (select 1 from storage.objects o where o.bucket_id = 'drop-assets' and o.name = v_thumbnail)
     or (v_photo is not null
         and not exists (select 1 from storage.objects o where o.bucket_id = 'drop-assets' and o.name = v_photo)) then
    raise exception 'not_copied' using errcode = 'P0001';
  end if;

  update public.assets a set
    status = 'approved',
    public_model_path = v_model,
    public_thumbnail_path = v_thumbnail,
    public_photo_path = v_photo
  where a.id = v.id;

  return jsonb_build_object('model', v_model, 'thumbnail', v_thumbnail, 'photo', v_photo);
end;
$$;

revoke execute on function public.publish_asset(uuid) from public, anon;
grant execute on function public.publish_asset(uuid) to authenticated;

-- Approving a drop needs its upload published first. Not approving it turns the
-- upload down too; putting it back in the queue reopens the upload.
create or replace function public.review_drop(drop_id text, decision text, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_drop public.drops;
  v_reason text := nullif(btrim(review_drop.reason), '');
  v_asset public.assets;
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  if review_drop.decision not in ('approve', 'reject', 'reopen') then
    raise exception 'bad_decision' using errcode = 'P0001';
  end if;
  if review_drop.decision = 'reject' and v_reason is null then
    raise exception 'reason_needed' using errcode = 'P0001';
  end if;

  select a.* into v_asset
  from public.drops d join public.assets a on a.id = d.asset_id
  where d.id = review_drop.drop_id;
  if review_drop.decision = 'approve' and v_asset.id is not null and v_asset.status <> 'approved' then
    raise exception 'asset_not_published' using errcode = 'P0001';
  end if;

  update public.drops d set
    review = case review_drop.decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'pending' end,
    review_reason = case when review_drop.decision = 'reject' then v_reason end
  where d.id = review_drop.drop_id
  returning d.* into v_drop;

  if v_drop.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;

  if v_asset.id is not null and review_drop.decision = 'reject' then
    update public.assets a set status = 'rejected', public_model_path = null,
      public_thumbnail_path = null, public_photo_path = null
    where a.id = v_asset.id;
  elsif v_asset.id is not null and review_drop.decision = 'reopen' and v_asset.status = 'rejected' then
    update public.assets a set status = 'pending' where a.id = v_asset.id;
  end if;

  insert into public.moderation_events (drop_id, drop_title, actor_id, action, reason)
  values (v_drop.id, v_drop.title, auth.uid(), review_drop.decision, v_reason);

  if review_drop.decision in ('approve', 'reject') then
    update public.reports r set
      status = case review_drop.decision when 'approve' then 'dismissed' else 'resolved' end,
      resolution = v_reason,
      resolved_by = auth.uid(),
      resolved_at = now()
    where r.drop_id = v_drop.id and r.status = 'open';
  end if;

  return public.drop_to_json(v_drop);
end;
$$;
