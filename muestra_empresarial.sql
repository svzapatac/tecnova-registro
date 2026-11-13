-- Muestra empresarial TECNOVA 2026: tabla + función de registro (la llama el formulario muestra.html)
create table if not exists public.muestra_empresarial (
  id bigint generated always as identity primary key,
  empresa text not null,
  n_participantes int not null check (n_participantes between 1 and 10),
  participantes jsonb not null,            -- [{nombre, cedula, correo}]
  sitio_web text,
  red_social text,                         -- Instagram, Facebook, TikTok, LinkedIn, X, Otra
  red_usuario text,                        -- usuario o URL
  creado_en timestamptz not null default now()
);
alter table public.muestra_empresarial enable row level security;

create or replace function public.muestra_registrar(
  p_empresa text, p_participantes jsonb, p_web text, p_red text, p_usuario text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int := jsonb_array_length(coalesce(p_participantes,'[]'::jsonb));
begin
  if coalesce(trim(p_empresa),'') = '' then raise exception 'empresa requerida'; end if;
  if n < 1 or n > 10 then raise exception 'participantes invalido'; end if;
  if coalesce(trim(p_web),'') = '' and coalesce(trim(p_usuario),'') = '' then
    raise exception 'web o red social requerida'; end if;
  insert into public.muestra_empresarial(empresa, n_participantes, participantes, sitio_web, red_social, red_usuario)
  values (trim(p_empresa), n, p_participantes, nullif(trim(p_web),''), nullif(trim(p_red),''), nullif(trim(p_usuario),''));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.muestra_registrar(text, jsonb, text, text, text) to anon;

-- Ver registros:
-- select empresa, n_participantes, participantes, sitio_web, red_social, red_usuario, creado_en from public.muestra_empresarial order by creado_en desc;
