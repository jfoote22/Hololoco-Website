-- Storage only deletes files the person can also see, so staff need to see the
-- public bucket's files through the API to take them down. (Everyone can already
-- fetch them by address; this only adds listing and deleting for staff.)
create policy "Staff see published files" on storage.objects
  for select to authenticated
  using (bucket_id = 'drop-assets'
         and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.is_staff));
