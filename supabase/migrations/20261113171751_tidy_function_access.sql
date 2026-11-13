-- Follow-ups from Supabase's advisors after people_and_drops.
--
-- is_staff() is only for the database's own rules (the drops trigger runs it as
-- its owner), so it doesn't need to be callable through the API.
revoke execute on function public.is_staff() from public, anon, authenticated;

-- Covers the foreign key from drops to the ready-made objects.
create index drops_object_idx on public.drops (object_id);

-- The other definer functions callable by visitors (public_drop,
-- public_drops_in_bounds, search_public_drops) and by signed-in people
-- (my_drops) are meant to be: they are the only way to read drops, and each
-- returns only what that caller may see.
