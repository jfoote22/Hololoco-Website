-- Found events, in bulk: approve or decline many at once from the review list, and a
-- count of what's waiting for the link on Your drops.

-- Each one goes through review_found, so the rules are the same; one that can't be
-- done (say, it's already over) is reported and the rest carry on.
create function public.review_found_many(found_ids text[], decision text, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id text;
  v_done integer := 0;
  v_failed jsonb := '[]'::jsonb;
begin
  if not public.is_staff() then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if decision not in ('approve', 'reject', 'pending') then
    raise exception 'bad_decision' using errcode = 'P0001';
  end if;
  if coalesce(cardinality(found_ids), 0) > 500 then
    raise exception 'too_many' using errcode = 'P0001';
  end if;

  foreach v_id in array coalesce(found_ids, '{}'::text[]) loop
    begin
      perform public.review_found(v_id, decision, null, null, null, reason);
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed || jsonb_build_object('id', v_id, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('done', v_done, 'failed', v_failed);
end;
$$;

create function public.found_waiting_count()
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  return (select count(*) from public.found_events e where e.status = 'pending');
end;
$$;

revoke execute on function public.review_found_many(text[], text, text) from public, anon;
revoke execute on function public.found_waiting_count() from public, anon;
grant execute on function public.review_found_many(text[], text, text) to authenticated;
grant execute on function public.found_waiting_count() to authenticated;
