-- Uploaded models can have up to 20,000 triangles after simplifying (was 10,000).
alter table public.assets drop constraint assets_triangles_check;
alter table public.assets add constraint assets_triangles_check
  check (triangles is null or triangles between 1 and 20000);
