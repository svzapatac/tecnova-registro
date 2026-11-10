-- =====================================================================
--  TECNOVA 2026 · Chatbot v3 (WhatsApp): programa oficial v15, sede Techne, corrección de datos y panel con TODAS las conversaciones
--  Pegar completo en Supabase → SQL Editor → New query → Run (se puede repetir sin problema)
--  Requiere haber corrido antes: supabase_bot.sql. Ya incluye todo lo del panel v2 (columna sin_leer, etc.).
-- =====================================================================

-- 0) Base del panel (v2), incluida aquí para no depender de otro archivo
-- =====================================================================
--  TECNOVA 2026 · Chatbot v2: panel de atención humana + seguimiento (que ningún contacto se pierda)
--  Pegar completo en Supabase → SQL Editor → New query → Run (se puede repetir sin problema)
--  Requiere haber corrido antes: supabase_bot.sql
-- =====================================================================
alter table public.bot_mensajes    add column if not exists humano boolean not null default false;
alter table public.bot_chats       add column if not exists sin_leer boolean not null default false;
alter table public.bot_chats       add column if not exists ultimo_cliente timestamptz;
alter table public.bot_chats       add column if not exists recordatorios int not null default 0;
alter table public.bot_chats       add column if not exists ultimo_aviso timestamptz;
alter table public.bot_escalaciones add column if not exists atendida_en timestamptz;
create index if not exists bot_escalaciones_wa_idx on public.bot_escalaciones (wa_id, id desc);
create index if not exists bot_chats_ultima_idx on public.bot_chats (ultima_en desc);

-- 1) Llega un mensaje (reemplaza la versión anterior): igual que antes + marca "sin leer" si hay una persona atendiendo
create or replace function public.bot_recibir(p_wa text, p_msg text, p_texto text, p_nombre text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare nuevo boolean; h timestamptz; ult int;
begin
  insert into public.bot_entrantes (msg_id, wa_id) values (p_msg, p_wa) on conflict do nothing; get diagnostics ult = row_count; nuevo := ult > 0;
  if not nuevo then return jsonb_build_object('nuevo', false); end if;
  insert into public.bot_chats (wa_id, nombre, ultimo_cliente) values (p_wa, p_nombre, now())
    on conflict (wa_id) do update set ultima_en = now(), ultimo_cliente = now(), nombre = coalesce(nullif(excluded.nombre, ''), public.bot_chats.nombre);
  if public.bot_norm(p_texto) ~ '^\s*(volver al bot|bot|menu)\s*$' then
    update public.bot_chats set humano_hasta = null, sin_leer = false, recordatorios = 0 where wa_id = p_wa;
    update public.bot_escalaciones set atendida = true, atendida_en = now() where wa_id = p_wa and not atendida;
  end if;
  select humano_hasta into h from public.bot_chats where wa_id = p_wa;
  if (select count(*) from public.bot_entrantes where wa_id = p_wa and creado_en > now() - interval '1 hour') > 40 then return jsonb_build_object('nuevo', true, 'limite', true, 'humano', false); end if;
  insert into public.bot_mensajes (wa_id, rol, texto) values (p_wa, 'user', left(p_texto, 2000));
  if coalesce(h > now(), false) then update public.bot_chats set sin_leer = true where wa_id = p_wa; end if;
  return jsonb_build_object('nuevo', true, 'limite', false, 'humano', coalesce(h > now(), false));
end $$;

-- 2) Antes de contestar (el bot espera unos segundos para juntar mensajes seguidos): ¿sigo siendo el último? + historial fresco
create or replace function public.bot_contexto(p_wa text, p_msg text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ult text; h timestamptz; nom text;
begin
  select msg_id into ult from public.bot_entrantes where wa_id = p_wa order by creado_en desc, msg_id desc limit 1;
  select humano_hasta, nombre into h, nom from public.bot_chats where wa_id = p_wa;
  return jsonb_build_object('es_ultimo', ult = p_msg, 'humano', coalesce(h > now(), false), 'nombre', nom,
    'historial', coalesce((select jsonb_agg(jsonb_build_object('role', rol, 'content', texto) order by id) from (select * from public.bot_mensajes where wa_id = p_wa order by id desc limit 16) x), '[]'::jsonb));
end $$;

-- 3) Pasar a una persona (reemplaza la anterior): además deja el chat marcado como "esperando" para el panel y los recordatorios
create or replace function public.bot_escalar(p_wa text, p_doc text, p_motivo text, p_resumen text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into public.bot_escalaciones (wa_id, documento, motivo, resumen) values (p_wa, nullif(p_doc, ''), left(p_motivo, 300), left(p_resumen, 1500));
  insert into public.bot_chats (wa_id) values (p_wa) on conflict do nothing;
  update public.bot_chats set humano_hasta = now() + interval '12 hours', sin_leer = true, recordatorios = 0, ultimo_aviso = now(), ultimo_cliente = coalesce(ultimo_cliente, now()) where wa_id = p_wa;
  return jsonb_build_object('ok', true);
end $$;

-- 4) Panel: lista de conversaciones (con mensajes) y mensajes que quedaron sin respuesta
create or replace function public.bot_panel_lista() returns jsonb language sql stable security definer set search_path = public as $$
  with ch as (
    select b.* from public.bot_chats b where b.ultima_en > now() - interval '7 days' or b.sin_leer order by b.sin_leer desc, b.ultima_en desc limit 80),
  sr as (
    select b.wa_id, b.nombre, u.creado_en as desde, u.texto
    from public.bot_chats b join lateral (select * from public.bot_mensajes where wa_id = b.wa_id order by id desc limit 1) u on true
    where u.rol = 'user' and u.creado_en < now() - interval '3 minutes' and u.creado_en > now() - interval '3 days' and not coalesce(b.humano_hasta > now(), false))
  select jsonb_build_object('ahora', now(),
    'chats', coalesce((select jsonb_agg(jsonb_build_object(
        'wa_id', ch.wa_id, 'nombre', nullif(ch.nombre, ''), 'humano', coalesce(ch.humano_hasta > now(), false), 'sin_leer', ch.sin_leer,
        'ultimo_cliente', ch.ultimo_cliente, 'ultima', ch.ultima_en,
        'escalacion', (select jsonb_build_object('id', e.id, 'motivo', e.motivo, 'resumen', e.resumen, 'documento', e.documento, 'creado_en', e.creado_en, 'atendida', e.atendida) from public.bot_escalaciones e where e.wa_id = ch.wa_id order by e.id desc limit 1),
        'mensajes', coalesce((select jsonb_agg(jsonb_build_object('rol', m.rol, 'texto', m.texto, 'humano', m.humano, 't', m.creado_en) order by m.id) from (select * from public.bot_mensajes where wa_id = ch.wa_id order by id desc limit 40) m), '[]'::jsonb))
      order by ch.sin_leer desc, ch.ultima_en desc) from ch), '[]'::jsonb),
    'sin_responder', coalesce((select jsonb_agg(jsonb_build_object('wa_id', sr.wa_id, 'nombre', nullif(sr.nombre, ''), 'desde', sr.desde, 'texto', sr.texto) order by sr.desde) from sr), '[]'::jsonb)) $$;

-- 5) Panel: una persona del equipo respondió (se guarda en la conversación y se atiende la escalación)
create or replace function public.bot_panel_enviar(p_wa text, p_texto text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into public.bot_chats (wa_id) values (p_wa) on conflict do nothing;
  insert into public.bot_mensajes (wa_id, rol, texto, humano) values (p_wa, 'assistant', left(p_texto, 4000), true);
  update public.bot_chats set humano_hasta = now() + interval '12 hours', sin_leer = false, recordatorios = 0, ultima_en = now() where wa_id = p_wa;
  update public.bot_escalaciones set atendida = true, atendida_en = now() where wa_id = p_wa and not atendida;
  return jsonb_build_object('ok', true);
end $$;

-- 6) Panel: tomar la conversación / marcarla leída / devolverla al bot (queda resuelta)
create or replace function public.bot_panel_accion(p_wa text, p_accion text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into public.bot_chats (wa_id) values (p_wa) on conflict do nothing;
  if p_accion = 'tomar' then
    update public.bot_chats set humano_hasta = now() + interval '12 hours', sin_leer = false, recordatorios = 0 where wa_id = p_wa;
  elsif p_accion = 'leer' then
    update public.bot_chats set sin_leer = false where wa_id = p_wa;
  elsif p_accion = 'devolver' then
    update public.bot_chats set humano_hasta = null, sin_leer = false, recordatorios = 0 where wa_id = p_wa;
    update public.bot_escalaciones set atendida = true, atendida_en = now() where wa_id = p_wa and not atendida;
  else return jsonb_build_object('ok', false, 'error', 'accion_desconocida'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 7) Recordatorios (cada 5 min desde n8n): quien lleva más de 10 min esperando a una persona, hasta 3 avisos por correo
create or replace function public.bot_recordatorios() returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; n int;
begin
  with t as (
    update public.bot_chats set recordatorios = recordatorios + 1, ultimo_aviso = now()
    where sin_leer and humano_hasta > now() and recordatorios < 3
      and greatest(coalesce(ultimo_aviso, '-infinity'::timestamptz), coalesce(ultimo_cliente, '-infinity'::timestamptz)) < now() - interval '10 minutes'
    returning wa_id, nombre, ultimo_cliente,
      (select e.motivo from public.bot_escalaciones e where e.wa_id = bot_chats.wa_id order by e.id desc limit 1) as motivo)
  select coalesce(jsonb_agg(jsonb_build_object('wa_id', wa_id, 'nombre', nullif(nombre, ''), 'desde', ultimo_cliente, 'motivo', motivo)), '[]'::jsonb) into r from t;
  select count(*) into n from public.bot_chats b
   where not coalesce(b.humano_hasta > now(), false)
     and (select m.rol from public.bot_mensajes m where m.wa_id = b.wa_id order by m.id desc limit 1) = 'user'
     and (select m.creado_en from public.bot_mensajes m where m.wa_id = b.wa_id order by m.id desc limit 1) between now() - interval '3 days' and now() - interval '3 minutes';
  return jsonb_build_object('pendientes', r, 'sin_responder', n);
end $$;

revoke all on function public.bot_recibir(text,text,text,text), public.bot_contexto(text,text), public.bot_escalar(text,text,text,text), public.bot_panel_lista(), public.bot_panel_enviar(text,text), public.bot_panel_accion(text,text), public.bot_recordatorios() from public, anon, authenticated;
grant execute on function public.bot_recibir(text,text,text,text), public.bot_contexto(text,text), public.bot_escalar(text,text,text,text), public.bot_panel_lista(), public.bot_panel_enviar(text,text), public.bot_panel_accion(text,text), public.bot_recordatorios() to service_role;

-- 1) Programa (cargado del programa del profe, versión v15): agenda general + cada ponencia con su sala
truncate public.bot_programa restart identity;
insert into public.bot_programa (dia, hora, ini, actividad, sala, cod, titulo, ponentes, inst) values
('2026-11-11'::date,'07:30 – 08:30','07:30','Registro de asistentes','','','','',''),
('2026-11-11'::date,'08:30 – 09:00','08:30','Apertura del congreso','','','','Msc. Rocío Rodríguez Guerrero, década de la Facultad Tecnológica y la Ing. Nancy Esperanza Olarte López, directora de la Red de Programas Tecnológicos TEC-RED',''),
('2026-11-11'::date,'09:00 – 09:45','09:00','Conferencia magistral','','','Ética profesional y ciberseguridad: binomio inseparable','Jaime Alberto Báez Peñuela / Consejo Profesional Nacional de Ingeniería – COPNIA.',''),
('2026-11-11'::date,'09:45 – 10:30','09:45','Conferencia magistral','','','DeepTech y capital de riesgo','Juan David Martínez Toro / Olarte Moure & Asociados',''),
('2026-11-11'::date,'10:30 – 11:00','10:30','Café','','','','',''),
('2026-11-11'::date,'11:00 – 11:45','11:00','Conferencia magistral','','','CO-CREATING AI DECISION SUPPORT SYSTEMS FOR YPERLOCAL, PROACTIVE CLIMATE-HEALTH ADAPTATION: Urban:  Air Quality and Heatwaves in LMICs and High Vulnerability Settings / Cocreación de sistemas de apoyo a la toma de decisiones basados ​​en IA para una adaptación climática y sanitaria proactiva a nivel hiperlocal: calidad del aire urbano y olas de calor en países de ingresos bajos y medios (PIBM) y entornos de alta vulnerabilidad','Ph.D. Plinio Morita / Ubiquitous Health Technology Lab / University of Waterloo',''),
('2026-11-11'::date,'11:45 – 12:00','11:45','Cierre','','','','',''),
('2026-11-12'::date,'07:30 – 08:00','07:30','Registro de asistentes','','','','',''),
('2026-11-12'::date,'08:00 – 08:30','08:00','Bienvenida y apertura','','','','M.Eng. B.Eng. Javier Alejandro Sáenz Leguizamón, Coordinador de la Jornada',''),
('2026-11-12'::date,'08:30 – 09:15','08:30','Charla: Ruta de Empleabilidad Socios Talento Capital','','','','Miguel Parraga / Secretaría de Desarrollo Económico',''),
('2026-11-12'::date,'09:15 – 10:00','09:15','Charla: Marketing estratégico en época de cambios','','','','Laura Rodríguez / Servicio Nacional de Aprendizaje – SENA',''),
('2026-11-12'::date,'10:00 – 10:45','10:00','Charla: Avanzando en las Ciencias de Computación','','','','Marcela Escobar García, Oracle Academy Country Manager – Multi Country Region',''),
('2026-11-12'::date,'10:45 – 11:45','10:45','Presentación de empresas','','','','Empresas participantes',''),
('2026-11-12'::date,'11:45 – 12:30','11:45','Networking y cierre de la feria','','','','Empresas y asistentes',''),
('2026-11-13'::date,'07:30 – 08:00','07:30','Registro de asistentes','','','','',''),
('2026-11-13'::date,'08:00 – 08:30','08:00','Bienvenida y apertura','','','','Yadira García Pacheco / Fundación Universitaria Compensar, Rosita Alacantara Poma / Universidad Nacional Mayor de San Marcos y Gustavo Andrés Romero Duque / Universidad Distrital Francisco José de Caldas, coordinadores de la Jornada.',''),
('2026-11-13'::date,'08:30 – 09:00','08:30','P4S: plataforma para eventos de emprendimiento','','','','Fundación Universitaria Compensar (Colombia)',''),
('2026-11-13'::date,'09:00 – 09:30','09:00','Green Deal Perú, es una startup peruana fundada en Lima en 2020 (con origen en una tesis universitaria en 2019) que impulsa la economía circular mediante la revalorización de residuos de aparatos eléctricos y electrónicos (RAEE)','','','','Benjamín Osco, CEO / Universidad Nacional Mayor de San Marcos (Perú)',''),
('2026-11-13'::date,'09:30 – 10:00','09:30','Agroglim, startup biotecnológica orientada a combatir los efectos del cambio climático con un Bioestimulante para el cacao.','','','','Katia Ñaupari Vega / Universidad Nacional Mayor de San Marcos (Perú)',''),
('2026-11-13'::date,'10:00 – 10:30','10:00','Startup Sena','','','','SENA (Colombia)',''),
('2026-11-13'::date,'10:30 – 11:00','10:30','Startup Sena','','','','SENA (Colombia)',''),
('2026-11-13'::date,'11:00 – 13:00','11:00','Pitch de equipos emprendedores','','','','4 equipos · Fundación Universitaria Compensar (Colombia)',''),
('2026-11-13'::date,'11:00 – 13:00','11:00','Pitch de equipos emprendedores','','','','3 equipos · Universidad Nacional Mayor de San Marcos (Perú)',''),
('2026-11-13'::date,'11:00 – 13:00','11:00','Pitch de equipos emprendedores','','','','3 equipos · Universidad Distrital Francisco José de Caldas (Colombia)',''),
('2026-11-13'::date,'11:00 – 13:00','11:00','Pitch de equipos emprendedores','','','','2 equipos · Universidad Antonio Nariño (Colombia)',''),
('2026-11-13'::date,'13:00 – 14:00','13:00','Receso (almuerzo)','','','','',''),
('2026-11-13'::date,'14:00 – 14:30','14:00','Cultura Emprendedora Inteligente: El Poder de la IA para Transformar Ideas en Negocios','','','','Mg. Carlos Bermúdez Mendoza, Gerente de Vinculación Empresarial, Incubadora 1551 / Universidad Nacional Mayor de San Marcos (Perú)',''),
('2026-11-13'::date,'14:30 – 15:00','14:30','Emprendimiento e innovación disruptiva. Caso Colombia 2026','','','','Mg. Tomás Martínez / Fundación Universitaria Compensar (Colombia)',''),
('2026-11-13'::date,'15:00 – 15:30','15:00','Emprendimiento en la era de la industria 4.0: experiencias desde la manufactura digital','','','','Ing. Pedro Sánchez / Universidad Militar Nueva Granada (Colombia)',''),
('2026-11-13'::date,'15:30 – 16:00','15:30','Innovación distrital y desarrolla sostenible','','','','Jorge Luis Inche Mitma, Director de la Incubadora 1551 / Universidad Nacional Mayor de San Marcos (Perú)',''),
('2026-11-13'::date,'16:00 – 16:30','16:00','¿Cómo transformar una idea de emprendimiento en una oportunidad de negocio?','','','','Yenny Constanza Sánchez / Orientadora del Fondo Emprender (Colombia)',''),
('2026-11-13'::date,'16:30 – 17:00','16:30','Resiliencia, pensamiento disruptivo, co-creacion claves para emprender','','','','Enit Godoy Estrella / Universidad Militar Nueva Granada (Colombia)',''),
('2026-11-13'::date,'17:00 – 17:30','17:00','Cierre del congreso','','','','',''),
('2026-11-11'::date,'14:00','14:00','Ponencia','P01','11','Desarrollo de un chasis ligero para dron agropecuario: optimización de diseño, manufactura y testeo','Gabriel Sánchez Bejarano, Jovanny Alejandro Pacheco Bolívar','Universidad del Valle'),
('2026-11-11'::date,'14:20','14:20','Ponencia','P01','21','Diseño y evaluación de una arquitectura de interconexión segura entre la sede Fundación Universitaria Compensar y la sede C.U.R. de Compensar','Juan Melquicedet Galindo Joya, Elkin Andrés Ladino Ordóñez','Fundación Universitaria Compensar'),
('2026-11-11'::date,'14:40','14:40','Ponencia','P01','22','Aplicación del modelo en V al diseño de un sistema mecatrónico patentado para la caracterización de materiales solidos mediante la medición de los coeficientes de fricción estático y dinámico','Luis David Mendoza Osorio','Fundación Universitaria Tecnológico Comfenalco'),
('2026-11-11'::date,'15:00','15:00','Ponencia','P01','28','Diseño e implementación de una solución de software para la detección temprana del cáncer de mama mediante inteligencia artificial','Angie Paola Rique Sabogal, Eddy Johana Ortega Carrillo, Juan Andrés Guacaneme Oviedo, Brayan Hernández Manrique','Fundación Universitaria Compensar'),
('2026-11-11'::date,'15:20','15:20','Ponencia','P01','29','Marco de validación multicapa para sistemas de inteligencia artificial aplicados al tamizaje de cáncer de mama','Angie Paola Rique Sabogal, Angie Lorena Urrego Lombana, Jessica Tatiana Álvarez Tique, Alexander Rueda Dueñas','Fundación Universitaria Compensar'),
('2026-11-11'::date,'14:00','14:00','Ponencia','P02','08','Jurimetría, informática jurídica y enfoques stream: como herramientas innovadoras para la transformación pedagógica del derecho en la educación superior','María Camila Escarria Delgado, John Henry Giraldo Morales, Milena Mena Cuesta','Tecnológico de Antioquia Institución Universitaria'),
('2026-11-11'::date,'14:20','14:20','Ponencia','P02','25','Simulador Académico en Seguridad Electrónica - SIA','José Mauricio Chirivi Sánchez, Nelson José Muñoz García, Jeisson Adrián Montealegre Rodríguez, Jeferson Arbey Bravo Sáenz, Elkin Andrés Ladino Ordóñez','Fundación Universitaria Compensar'),
('2026-11-11'::date,'14:40','14:40','Ponencia','P02','58','Microcurso de bioquímica basado en microlearning y WhatsApp','Juan Carlos Guevara Bolaños, Gloria Andrea Cavanzo Nisso, Miguel Ricardo Pérez Pereira','Universidad Distrital Francisco José de Caldas'),
('2026-11-11'::date,'15:00','15:00','Ponencia','P02','56','Entorno de pesca en realidad virtual para posaccidente cerebrováscular','Hubeimar Iván Fernández Miranda, Michael Andrés Acuña Gutiérrez, Juan Carlos Guevara Bolaños','Universidad Distrital Francisco José de Caldas'),
('2026-11-11'::date,'15:20','15:20','Ponencia','P02','23','Laboratorio experimental bola y barra para la enseñanza del PID','Brithon Susa Gaviria','Fundación Universitaria Tecnológico Comfenalco'),
('2026-11-11'::date,'15:40','15:40','Ponencia','P02','38','Inteligencia artificial en procesos de diseño gráfico: enfoque STEAM','Mónica Lizeth Sánchez Arévalo, Juan David Gutiérrez Herrera, Juan David Huérfano, María José López Rey','Politécnico Grancolombiano · Universidad Nacional de Colombia'),
('2026-11-11'::date,'14:00','14:00','Ponencia','P03','37','Prototipo preliminar de sistema hidropónico tipo NFT asistido por ESP32 para el monitoreo de variables en espacios reducidos','Jhonatan Paolo Tovar Soto, María Paula Galvis Orjuela, Andrés Santiago Rachen Papamija','Universidad San Buenaventura'),
('2026-11-11'::date,'14:20','14:20','Ponencia','P03','39','PsyBridge propuesta de asistente virtual de apoyo emocional','Nicolás Sanabria Urrea, Karol Stephanni Bohórquez Vásquez, Juan Diego Pérez Gonzales','Politécnico Grancolombiano'),
('2026-11-11'::date,'14:40','14:40','Ponencia','P03','33','Aprendizaje basado en retos mediante la plataforma MakeX para el fomento de competencias STEM en la educación básica y media','Sofía Santos Valderrama, Manuel Alejandro Hernández Gonzales, Juan Edward Ortiz Rojas, David Santiago Salamanca Valderrama','Universidad Distrital Francisco José de Caldas'),
('2026-11-11'::date,'15:00','15:00','Ponencia','P03','65','Desempeño deportivo de los Equipos de Fútbol Profesional Colombiano Primera A caracterizado como Tecnologías','Wilson Alexander Pinzón Rueda','Universidad Distrital Francisco José de Caldas'),
('2026-11-11'::date,'15:20','15:20','Ponencia','P03','66','Wikipedias, Producción Científica, Empresariado Comercio Exterior e Inteligencia Artificial Generativa','Wilson Alexander Pinzón Rueda, Román Leonardo Rodríguez Florián, Astrid del Socorro Altamar Consuegra','Universidad Distrital Francisco José de Caldas'),
('2026-11-11'::date,'15:40','15:40','Ponencia','P03','67','PULSO: Predicción y Simulación del Riesgo de Desabastecimiento de Medicamentos en Colombia','David Camilo Gutiérrez Novoa, David Esteban Martínez Berjarano, Sara Juliana Poveda Gamez, Santiago Alejandro Vergara Castro','Politécnico Grancolombiano'),
('2026-11-11'::date,'18:20','18:20','Ponencia','V01','13','IA aplicada a Finanzas','Valerie Alexandra Mendoza Charris','Universidad Autónoma del Caribe'),
('2026-11-11'::date,'18:40','18:40','Ponencia','V01','30','Presencia digital escolar: Página Web y Redes sociales Institucionales','Jem Marys Menco Zapata','SENA'),
('2026-11-11'::date,'19:00','19:00','Ponencia','V01','35','Diseño, construcción y validación de un prototipo mecatrónico: clasificación automática de envases de bebidas','Rhonal Leandro Rodríguez Rincón, Jonathan Andrés Chávez Blandón, José Felipe Hurtado, Adriana López Vargas','Universidad Antonio Nariño Sede sur'),
('2026-11-11'::date,'19:20','19:20','Ponencia','V01','40','Sistema de verificación biométrica para el programa de alimentación escolar (PAE) en cafeterías institucionales','Pedro Stiven Rivera Rodríguez, María Fernanda Gallo Díaz, Julián Andrey Ariza Obregón','Fundación Universitaria Compensar'),
('2026-11-11'::date,'19:40','19:40','Ponencia','V01','44','Detección de fibrilación auricular mediante procesamiento digital de señales PPG','Daniela Beltrán Molina, Lely Adriana Luengas Contreras, Nancy Esperanza Olarte López','Universidad Militar Nueva Granada · Universidad Distrital Francisco José de Caldas'),
('2026-11-11'::date,'20:00','20:00','Ponencia','V01','48','Evaluación de tecnologías para la adquisición de señales fotopletismográficas (PPG) mediante dispositivos móviles','Camilo Sánchez Cifuentes, Nancy Esperanza Olarte López, Carlos Antonio Orrego Muñoz, Gustavo Emilio Echeverry Vásquez','Universidad Militar Nueva Granada'),
('2026-11-11'::date,'18:20','18:20','Ponencia','V02','16','Clasificación Multietiqueta de Señales Electrocardiográficas de Doce Derivaciones mediante una Red Neuronal Residual Unidimensional','Jorge Eliecer Gómez Gómez, Carlos Daniel Flórez Pacheco, Sarah Córdoba Salgado','Universidad de Córdoba'),
('2026-11-11'::date,'18:40','18:40','Ponencia','V02','55','Análisis de la relación entre el uso de inteligencia artificial y el desarrollo del pensamiento lógico y computacional en estudiantes de programación apoyado en un modelo de analítica y visualización de datos','Keiven Miguel Padilla Diosa, Juan Andrés Vargas Polo','Universidad de Córdoba'),
('2026-11-11'::date,'19:00','19:00','Ponencia','V02','64','Modelo ontológico para la representación de la medicina tradicional afrocolombiana y palenquera en un sistema sensible al contexto','María Antonia Díaz Mendoza, Jorge Eliecer Gómez Gómez, Emiro De La Hoz Franco, Guisell Elena Bolaño Vásquez','Universidad de la Costa (CUC) · Universidad de Córdoba'),
('2026-11-11'::date,'19:20','19:20','Ponencia','V02','14','Arquitectura de ciberseguridad para IoT basada en ESP32-S3','Yordan Mauricio Rodríguez Anzola','Fundación Universitaria Compensar'),
('2026-11-11'::date,'19:40','19:40','Ponencia','V02','36','Detección de intrusiones en red con redes bayesianas interpretables: un análisis probabilístico sobre el conjunto de datos abierto NSL-KDD','Byron Wladimir Oviedo Bayas, Emilio Rodrigo Zhuma Mera, Ángel Iván Torres Quijije, Omar Andrés Oviedo Armijos','Universidad Técnica Estatal de Quevedo · Universidad Estatal de Milagro'),
('2026-11-11'::date,'18:20','18:20','Ponencia','V03','50','Prototipo mecatrónico para clasificación automática de envases de bebidas','Deeryck Adrián Gutiérrez Acosta, Adriana López Vargas, José Felipe Hurtado','Universidad Antonio Nariño'),
('2026-11-11'::date,'18:40','18:40','Ponencia','V03','41','Realidad virtual y prototipado 3D para evaluación ergonómica de prendas de protección balística','Wilmer Geovany Sepúlveda Manrique, Luis Guillermo Molero Suárez, Danny Bercelio González Pinzón, Marlon Andrey Garzón Guzmán, Juan Pablo Carreño Larrahondo','Fundación Universitaria Compensar · Universidad Militar Nueva Granada'),
('2026-11-11'::date,'19:00','19:00','Ponencia','V03','46','Patrones de influencia y persuasión automatizada en la ingeniería social 2.0','David Alexander Muñoz Rojas, Juliana Caterine Cifuentes Pachón, Fabiana López Piñeros, Nancy Esperanza Olarte López','Universidad Militar Nueva Granada'),
('2026-11-11'::date,'19:20','19:20','Ponencia','V03','09','Evaluación técnico-económica fotovoltaica en un equipamiento universitario patrimonial','Annia Arzola de la Peña','Universidad Internacional de Valencia (VIU)'),
('2026-11-11'::date,'19:40','19:40','Ponencia','V03','10','Distorsión armónica y desbalance de tensión en redes de distribución con generación fotovoltaica: análisis del estado del arte y mitigación','Santiago Rincón Castro, Dahiana López García','Universidad Nacional de Colombia'),
('2026-11-11'::date,'18:20','18:20','Ponencia','V04','71','Call of English: Diseño y creación de un ambiente e-learning para la enseñanza del inglés a través de la segunda guerra mundial en estudiantes de grado décimo','Carlos Castellanos, Claudia Mireya Chaves, Geraldine Flórez, Juan Pablo Marroquín,','Universidad Pedagógica Nacional'),
('2026-11-11'::date,'18:40','18:40','Ponencia','V04','72','Historia de las pandemias desde cuatro miradas: Un curso mediado por las TIC','Erika Brigith Ascuntar, Erikson Esneider Contreras, Ana Luiza De Paula Costa, Katrina Sarai Quiroga Muñoz, Juanita Rodriguez','Universidad Pedagógica Nacional'),
('2026-11-11'::date,'19:00','19:00','Ponencia','V04','18','Arquitectura multiagente para gestionar, propagar y publicar redes profesionales','Henry Antonio Roncancio Velandia','Universidad Militar Nueva Granada'),
('2026-11-11'::date,'19:20','19:20','Ponencia','V04','68','Plataforma digital para el diagnóstico de la madurez digital en pymes y colegios en el marco de la industria 4.0','Pedro José Sánchez Caimán','Universidad Militar Nueva Granada'),
('2026-11-11'::date,'19:40','19:40','Ponencia','V04','69','El en foque social de los fablab: Tecnología e innovación al servicios de la comunidad','Pedro José Sánchez Caimán','Universidad Militar Nueva Granada'),
('2026-11-12'::date,'14:00','14:00','Ponencia','P01','05','Evaluación multisemilla de aumentación para detectar cálices de uchuva','Diego Alejandro Amaya, Laura Camila Rincón Malaver, David Reinerio Yanguas Rojas','Uniagustiniana'),
('2026-11-12'::date,'14:20','14:20','Ponencia','P01','15','Sistema de clasificación de tumores cerebrales con IRM mediante un modelo de aprendizaje por transferencia','Jorge Eliecer Gómez Gómez, Velssy Liliana Hernández Riaño, Daniel Salas Álvarez, Byron Wladimir Oviedo Bayas','Universidad de Córdoba · Universidad Técnica Estatal de Quevedo Ecuador'),
('2026-11-12'::date,'14:40','14:40','Ponencia','P01','34','Optimización de la proporción de clases en conjuntos de datos mediante algoritmos genéticos para el balanceo de clases en problemas de clasificación de Machine Learning','María Isabel Vidal Caicedo, Néstor Milciades Díaz Mariño','Doctorado en Ciencias de la Computación - Universidad del Cauca · Facultad de Ingeniería Electrónica y Telecomunicaciones - Universidad del Cauca'),
('2026-11-12'::date,'15:00','15:00','Ponencia','P01','61','Sistema de integración y gestión de datos ambientales y de salud','Juan David López Marcelo, Andrés Julián Barreto Puerto, Juan Carlos Guevara Bolaños','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'15:20','15:20','Ponencia','P01','31','Evidencia de transferencia Sim2real en robótica móvil','Juan David Aguilar Ciro, Juan Camilo Durán Ávila, David Reinerio Yanguas Rojas','Uniagustiniana'),
('2026-11-12'::date,'14:00','14:00','Ponencia','P02','57','Laboratorio urbano de inteligencia ambiental y salud pública','Juan Carlos Guevara Bolaños, Gloria Andrea Cavanzo Nisso, Miguel Ricardo Pérez Pereira','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'14:20','14:20','Ponencia','P02','07','Proyecto astronómico escolar tecnoética: Una oportunidad de acercar la ciencia al territorio de Soacha (Xua Chá)','Óscar Javier Ballesteros Urrea','Doctorando en Educación, Universidad Santo Tomás, Colombia, Bogotá DC'),
('2026-11-12'::date,'14:40','14:40','Ponencia','P02','53','Innovación de base (Grassroots innovation) en asistencia social: un estudio a gran escala de repositorios públicos de software','Heric Gonzalo Jiménez Llancapani, Carlos Cares','Universidad de La Frontera, Temuco'),
('2026-11-12'::date,'15:00','15:00','Ponencia','P02','17','Del biosensor a la interfaz: integración arquitectónica para el procesamiento y visualización de señales biomédicas','Carlos Andrés Pérez Angarita','Universidad ECCI, Fundación del Área Andina'),
('2026-11-12'::date,'15:20','15:20','Ponencia','P02','19','Impacto del hardening en el rendimiento de dispositivos IoT de recursos limitados: estudio de caso con Raspberry Pi 3','Javier Alejandro Sáenz Leguizamón','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'14:00','14:00','Ponencia','P03','24','Optimización logística para la recolección y distribución de residuos textiles en una empresa de aprovechamiento','Ruth Milena Suárez Castro, Maykol Giovanny Amaya Moreno','Uniagustiniana'),
('2026-11-12'::date,'14:20','14:20','Ponencia','P03','32','PH-GNNBind: modelo de predicción de la afinidad proteína-ligando que integra homología persistente y redes neuronales de grafos','Ember Ubeimar Martínez Flor, Néstor Milciades Díaz Mariño','Universidad del Cauca'),
('2026-11-12'::date,'14:40','14:40','Ponencia','P03','24','Optimización logística para la recolección y distribución de residuos textiles en una empresa de aprovechamiento','Ruth Milena Suárez Castro, Maykol Giovanny Amaya Moreno','Uniagustiniana'),
('2026-11-12'::date,'15:00','15:00','Ponencia','P03','53','Innovación de base (Grassroots innovation) en asistencia social: un estudio a gran escala de repositorios públicos de software','Heric Gonzalo Jiménez Llancapani, Carlos Cares','Universidad de La Frontera, Temuco'),
('2026-11-12'::date,'15:20','15:20','Ponencia','P03','76','Ingeniería Social, más allá del phishing','Nidia Munevar','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'15:40','15:40','Ponencia','P03','77','Informe de actividades de calidad del aire: acciones realizadas y proyecciones','Ingeniero Óscar Javier Riaño Cipagauta','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'18:20','18:20','Ponencia','V05','01','El uso de la IA como estrategia didáctica para la labor docente en la educación superior','Rosa Audelia Tapia López, Rocío Edith López Martínez','Universidad Autónoma de Querétaro'),
('2026-11-12'::date,'18:40','18:40','Ponencia','V05','02','Heterogeneidad estudiantil en la brecha digital académica: perfiles y diferencias en la calidad percibida del entorno virtual de aprendizaje','Rodolfo Arias Becerra, Rocío Edith López Martínez','Universidad Autónoma de Querétaro'),
('2026-11-12'::date,'19:00','19:00','Ponencia','V05','06','Legitimidad pedagógica ante IAGen: reversibilidad formativa del juicio','Jorge Fabián Abud','Universidad Austral'),
('2026-11-12'::date,'19:20','19:20','Ponencia','V05','26','Implementación de un Sistema Integral de Simulación Aeronáutica con Arquitectura ROS para Entornos de Aprendizaje – AeroX','Juan Sebastián Montejo Castro, José Miguel Ladino Parrado, Laura Lucero Galindo Rodríguez, Juan José Morales Velandia','Fundación Universitaria Compensar'),
('2026-11-12'::date,'19:40','19:40','Ponencia','V05','47','Implementación de un Sistema Integral de Simulación Aeronáutica con Arquitectura ROS para Entornos de Aprendizaje – AeroX','Luis Arbey Corredor Chaves, José Miguel Ladino Parrado, Laura Lucero Galindo Rodríguez, Juan José Morales Velandia, Juan Sebastián Montejo Castro','Fundación Universitaria Compensar'),
('2026-11-12'::date,'20:00','20:00','Ponencia','V05','54','Diseño e implementación inicial de Mati como arquitectura conversacional para construir tutores pedagógicos de inteligencia artificial','Luis Alexander Fuentes','Universidad de El Salvador'),
('2026-11-12'::date,'18:20','18:20','Ponencia','V06','42','Influencia del bienestar organizacional en la motivación laboral','Mónica María Torres Arenas, Valeria Patricia Paternina Puello','Corporación Universitaria Minuto de Dios - UNIMINUTO'),
('2026-11-12'::date,'18:40','18:40','Ponencia','V06','43','De la apropiación individual al fortalecimiento institucional de las TIC: una revisión sistemática en medios digitales','Angie Emily Valentina Rodríguez Orozco, Sandra Liliana Uribe Montaña, Nancy Esperanza Olarte López','Universidad Militar Nueva Granada'),
('2026-11-12'::date,'19:00','19:00','Ponencia','V06','52','Identidad digital docente: ciberseguridad, reputación y huella virtual','Fernanda Esperanza Tusa Jumbo, Cristhian Rivera Orbe','Universidad Técnica de Machala'),
('2026-11-12'::date,'19:20','19:20','Ponencia','V06','12','A.M.A.Shield','Alejandro Moreno Alarcón, Dumar Prieto, Sebastián Vargas, Santiago Rodríguez','Fundación Universitaria Compensar'),
('2026-11-12'::date,'19:40','19:40','Ponencia','V06','27','Photovoltaic Output Power Prediction Using Data Science: A Comparative Study of Machine Learning and Deep Learning for a Campus-Scale System in Ecuador','Ángel Iván Torres Quijije, Nyla Raquel Vargas-Pilay, Jimmy Aldrin Cedeño Barzola, Eduardo Amable Samaniego Mena','Universidad Técnica Estatal de Quevedo'),
('2026-11-12'::date,'20:00','20:00','Ponencia','V06','03','Hospital Digital Interoperable: Reto de requerimientos para Colombia','Valentina Castro Ávila, Leonardo Juan Ramírez López','Universidad Militar Nueva Granada'),
('2026-11-12'::date,'18:20','18:20','Ponencia','V07','59','Microcurso en WhatsApp para cuidadores de personas con discapacidad','Juan Pablo Suesca Arévalo, Daniel Alejandro Muñetones Gómez, Juan Carlos Guevara Bolaños','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'18:40','18:40','Ponencia','V07','60','Microcurso móvil para la formulación de proyectos comunitarios','Julián Felipe Díaz Suárez, Juan Carlos Guevara Bolaños','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'19:00','19:00','Ponencia','V07','63','Implementación de un Sistema Integral de Simulación Aeronáutica con Arquitectura ROS para Entornos de Aprendizaje – AeroX','Laura Lucero Galindo Rodríguez, Juan José Morales Velandia, Juan Sebastián Montejo Castro, José Miguel Ladino Parrado, Luis Arbey Corredor Chaves','Fundación Universitaria Compensar, sede Meta'),
('2026-11-12'::date,'19:20','19:20','Ponencia','V07','09','Evaluación técnico-económica fotovoltaica en un equipamiento universitario patrimonial','Annia Arzola de la Peña','Universidad Internacional de Valencia (VIU)'),
('2026-11-12'::date,'19:40','19:40','Ponencia','V07','10','Distorsión armónica y desbalance de tensión en redes de distribución con generación fotovoltaica: análisis del estado del arte y mitigación','Santiago Rincón Castro, Dahiana López García','Universidad Nacional de Colombia'),
('2026-11-12'::date,'20:00','20:00','Ponencia','V07','45','Análisis de relojes inteligentes para la adquisición de señales PPG orientada a la detección de fibrilación auricular (FA)','Andrés José Acevedo Ávila, Esperanza Camargo Casallas, Jonathan Roberto Torres Castillo','Universidad Distrital Francisco José de Caldas'),
('2026-11-12'::date,'18:20','18:20','Ponencia','V08','49','Proyecto Bus Inter Conexión (BIC)','Brian David Celemin Meneses, Adhan Damián Cubillos Moreno, Martín Felipe Calderón Romero, Andrés Felipe Fernández Gómez, Luis Arbey Corredor Chaves','Fundación Universitaria Compensar'),
('2026-11-12'::date,'18:40','18:40','Ponencia','V08','73','Diseño e Implementación de un Nodo Ganadero Cognitivo de Doble Umbral Basado en TinyML y Estimación de Proximidad Relativa Basada en RSSI mediante LoRa para Zonas Rurales sin Conectividad','Ángel Felipe Cosme Mahecha, Jiver Ospino Vargas,','Fundación Universitaria Compensar'),
('2026-11-12'::date,'19:00','19:00','Ponencia','V08','70','ÁGIL-LEC: estrategia ágil para proyectos literarios universitarios','Martha Acosta Alvarez','Universidad de las Ciencias Informáticas'),
('2026-11-12'::date,'19:20','19:20','Ponencia','V08','04','Entropía en grafos de conectividad cerebral derivados de EEG/MEG: Mapeo exploratorio de alcance','Alejandra Silva Güiza, Leonardo Juan Ramírez López','Universidad Militar Nueva Granada'),
('2026-11-12'::date,'19:40','19:40','Ponencia','V08','74','Sistema IoT de bajo costo para el monitoreo en tiempo real de variables ambientales y calidad del aire en la parroquia Patricia Pilar, Ecuador','Emilio Rodrigo Zhuma Mera, Ángel Iván Torres Quijije, Byron Oviedo Bayas, Alexander Joseph Maigua Cervantes','Universidad Técnica Estatal de Quevedo'),
('2026-11-12'::date,'20:00','20:00','Ponencia','V08','75','Identidad digital docente: ciberseguridad, reputación y huella virtual','Fernanda Tusa, Cristhian Rivera','Universidad Técnica de Machala');
update public.bot_programa set texto_busqueda = public.bot_norm(concat_ws(' ', public.cert_fecha_es(dia), actividad, sala, cod, titulo, ponentes, inst));

-- 2) Salas: tipo, tema, moderador, enlace de transmisión y salón físico (Techne piso 8)
create table if not exists public.bot_salas (dia date not null, sala text not null, modalidad text, tema text, horario text, moderador text, enlace text, salon text, primary key (dia, sala));
truncate public.bot_salas;
insert into public.bot_salas (dia, sala, modalidad, tema, horario, moderador, enlace, salon) values
('2026-11-11'::date,'P01','Presencial','Desarrollo tecnológico','14:00 – 16:00','Profesor Gustavo Andrés Romero Duque','https://youtube.com/live/b2jGoKfi3QU?feature=share','salón 4'),
('2026-11-11'::date,'P02','Presencial','Innovación educativa','14:00 – 16:00','Profesora Adriana López Vargas','https://youtube.com/live/xW_1mQCZzos?feature=share','salón 7'),
('2026-11-11'::date,'P03','Presencial','Desarrollo tecnológico, innovación educativa e IA y analítica de datos','14:00 – 16:00','Profesor Héctor Iván Tangerife Escobar','https://youtube.com/live/a-FflhVkXz0?feature=share','salón 8'),
('2026-11-11'::date,'V01','Virtual','Desarrollo tecnológico','18:20 – 21:00','Profesor Juan Carlos Guevara Bolaños','Grabación',''),
('2026-11-11'::date,'V02','Virtual','IA y analítica de datos','18:20 – 21:00','Gloria Andrea Cavanzo Nisso','Grabación',''),
('2026-11-11'::date,'V03','Virtual','Realidad virtual, ciberseguridad, desarrollo tecnológico y tecnología para sostenibilidad','18:20 – 21:00','Profesora Catalina Suarez Pérez','https://www.youtube.com/watch?v=dkKV9KlavLg',''),
('2026-11-11'::date,'V04','Virtual','Transformación digital, desarrollo tecnológico e innovación educativa','18:20 – 21:00','Profesor Carlos Duarte Garzón','https://www.youtube.com/watch?v=JVxoBxgDlmk',''),
('2026-11-12'::date,'P01','Presencial','IA, Analítica de datos y gestión del conocimiento','14:00 – 17:00','Profesor Gustavo Andrés Romero Duque','https://youtube.com/live/kL4NXlpbahU?feature=share','salón 4'),
('2026-11-12'::date,'P02','Presencial','IA, Analítica de datos, gestión del conocimiento y ciberseguridad','14:00 – 16:00','Profesor Wilson Alexander Pinzón Rueda','https://youtube.com/live/tCyQpHur3MA?feature=share','salón 7'),
('2026-11-12'::date,'P03','Presencial','IA, Analítica de datos y gestión del conocimiento','14:00 – 16:00','Profesor Giovanni Sánchez Prieto','https://youtube.com/live/lXTJU6qazFg?feature=share','salón 8'),
('2026-11-12'::date,'V05','Virtual','Innovación educativa','18:20 – 21:00','Profesor Juan Carlos Guevara Bolaños','Grabación',''),
('2026-11-12'::date,'V06','Virtual','Gestión del conocimiento e IoT y sistemas inteligentes conectados','18:20 – 21:00','Gloria Andrea Cavanzo Nisso','Grabación',''),
('2026-11-12'::date,'V07','Virtual','Innovación educativa, IoT y sistemas inteligentes interconectados','18:20 – 21:00','Profesora Catalina Suarez Pérez','https://www.youtube.com/watch?v=qVz4HKe9XL4',''),
('2026-11-12'::date,'V08','Virtual','IoT y sistemas inteligentes y gestión del conocimiento','18:20 – 21:00','Profesor Carlos Duarte Garzón','https://www.youtube.com/watch?v=3XZBi5Eayxo','');
alter table public.bot_salas enable row level security;
revoke all on public.bot_salas from anon, authenticated;

-- 3) Buscar en el programa: ahora también devuelve el lugar exacto (salón del Techne), moderador y enlace
create or replace function public.bot_buscar_programa(p_q text, p_limite int default 8) returns jsonb language sql stable security definer set search_path = public as $$
  with w as (select unnest(string_to_array(regexp_replace(public.bot_norm(p_q), '[^a-z0-9 ]', ' ', 'g'), ' ')) t),
  k as (select t from w where length(t) >= 3 or t ~ '^(p|v)[0-9]{2}$' or t ~ '^[0-9]{1,2}$'),
  s as (select p.*, (select count(*) from k where p.texto_busqueda like '%' || k.t || '%') as puntos from public.bot_programa p)
  select coalesce(jsonb_agg(jsonb_build_object('dia', public.cert_fecha_es(z.dia), 'hora', z.hora, 'actividad', z.actividad, 'sala', nullif(z.sala,''), 'codigo', nullif(z.cod,''), 'titulo', nullif(z.titulo,''), 'ponentes', nullif(z.ponentes,''), 'institucion', nullif(z.inst,''),
      'modalidad', sa.modalidad, 'salon_techne_piso_8', sa.salon, 'moderador', sa.moderador, 'enlace_transmision', case when sa.enlace ilike 'http%' then sa.enlace end)
    order by z.puntos desc, z.dia, z.ini), '[]'::jsonb)
  from (select * from s where puntos > 0 order by puntos desc, dia, ini limit greatest(least(p_limite, 12), 1)) z
  left join public.bot_salas sa on sa.dia = z.dia and sa.sala = z.sala $$;

-- 4) Corrección de nombre/apellido (por chat): valida, deja registro, actualiza y vuelve a enviar escarapela, certificados e insignias
create table if not exists public.bot_correcciones (id bigserial primary key, wa_id text, registro_id uuid, documento text, antes text, despues text, creado_en timestamptz not null default now());
alter table public.bot_correcciones enable row level security;
revoke all on public.bot_correcciones from anon, authenticated;

-- columnas de reenvío de insignias (ya existen si corriste el SQL de insignias; esto es solo por seguridad)
alter table public.asist_insignias add column if not exists envio_estado text not null default 'PENDIENTE';
alter table public.asist_insignias add column if not exists tomado_en timestamptz;
alter table public.asist_insignias add column if not exists intentos int not null default 0;

create or replace function public.bot_titulo(t text) returns text language sql immutable as $$
  select coalesce(string_agg(case when w <> lower(w) and w <> upper(w) then w when lower(w) in ('de','del','la','las','los','y','da','di','do','dos','van','von') then lower(w) else upper(left(w,1)) || lower(substr(w,2)) end, ' '), '')
    from regexp_split_to_table(btrim(regexp_replace(coalesce(t,''), '\s+', ' ', 'g')), ' ') w $$;

create or replace function public.bot_corregir_datos(p_wa text, p_doc text, p_nombres text default null, p_apellidos text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.registros%rowtype; d text := regexp_replace(upper(coalesce(p_doc,'')), '[^A-Z0-9]', '', 'g');
        nn text := nullif(public.bot_titulo(p_nombres), ''); na text := nullif(public.bot_titulo(p_apellidos), ''); completo text; k int; c_cert int := 0; c_ins int := 0;
begin
  if nn is null and na is null then return jsonb_build_object('ok', false, 'motivo', 'falta_dato'); end if;
  if (nn is not null and nn !~ '^[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ''’. -]*$') or (na is not null and na !~ '^[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ''’. -]*$') or length(coalesce(nn,'')) > 60 or length(coalesce(na,'')) > 60 then
    return jsonb_build_object('ok', false, 'motivo', 'formato_invalido'); end if;
  select * into r from public.registros where regexp_replace(upper(documento), '[^A-Z0-9]', '', 'g') = d order by creado_en desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'no_registrado'); end if;
  select count(*) into k from public.bot_correcciones where registro_id = r.id;
  if k >= 3 then return jsonb_build_object('ok', false, 'motivo', 'limite_correcciones'); end if;
  insert into public.bot_correcciones (wa_id, registro_id, documento, antes, despues) values (p_wa, r.id, d, r.nombres || ' | ' || r.apellidos, coalesce(nn, r.nombres) || ' | ' || coalesce(na, r.apellidos));
  update public.registros set nombres = coalesce(nn, nombres), apellidos = coalesce(na, apellidos) where id = r.id;
  completo := public.bot_titulo(coalesce(nn, r.nombres) || ' ' || coalesce(na, r.apellidos));
  -- ponencias: el nombre impreso sale de la relación de autores
  update public.pon_autores set nombre = completo where lower(correo) = lower(r.correo);
  -- escarapela (sticker): vuelve a la cola de envío
  update public.registros set estado = 'PENDIENTE', intentos = 0, error = null where id = r.id and estado in ('ENVIADO', 'ERROR');
  -- certificados ya enviados o con error: nombre nuevo y vuelven a la cola; los pendientes toman el nombre nuevo solos
  update public.cert_envios set nombre_cert = case when nombre_cert is not null then completo else nombre_cert end where registro_id = r.id;
  update public.cert_envios set estado = 'PENDIENTE', intentos = 0, error = null, disponible_desde = now() where registro_id = r.id and estado in ('ENVIADO', 'ERROR');
  get diagnostics c_cert = row_count;
  -- insignias ya enviadas: se vuelven a enviar con el nombre corregido
  update public.asist_insignias set enviada = false, envio_estado = 'PENDIENTE', intentos = 0 where registro_id = r.id and insignia and enviada;
  get diagnostics c_ins = row_count;
  return jsonb_build_object('ok', true, 'nombre_nuevo', completo, 'certificados_reenviados', c_cert, 'insignias_reenviadas', c_ins, 'escarapela_reenviada', true, 'correo_enmascarado', regexp_replace(r.correo, '^(.{1,2}).*(@.*)$', '\1***\2'));
end $$;

-- 5) Panel: lista de TODAS las conversaciones (sin límite de días), con el último mensaje de cada una
create or replace function public.bot_panel_lista() returns jsonb language sql stable security definer set search_path = public as $$
  with ch as (select b.* from public.bot_chats b order by b.sin_leer desc, b.ultima_en desc limit 1000),
  sr as (
    select b.wa_id, b.nombre, u.creado_en as desde, u.texto
    from public.bot_chats b join lateral (select * from public.bot_mensajes where wa_id = b.wa_id order by id desc limit 1) u on true
    where u.rol = 'user' and u.creado_en < now() - interval '3 minutes' and u.creado_en > now() - interval '3 days' and not coalesce(b.humano_hasta > now(), false))
  select jsonb_build_object('ahora', now(),
    'total', (select count(*) from public.bot_chats),
    'chats', coalesce((select jsonb_agg(jsonb_build_object(
        'wa_id', ch.wa_id, 'nombre', nullif(ch.nombre, ''), 'humano', coalesce(ch.humano_hasta > now(), false), 'sin_leer', ch.sin_leer,
        'ultimo_cliente', ch.ultimo_cliente, 'ultima', ch.ultima_en,
        'n_msgs', (select count(*) from public.bot_mensajes m where m.wa_id = ch.wa_id),
        'ult', (select jsonb_build_object('rol', m.rol, 'humano', m.humano, 'texto', left(m.texto, 140), 't', m.creado_en) from public.bot_mensajes m where m.wa_id = ch.wa_id order by m.id desc limit 1),
        'escalacion', (select jsonb_build_object('id', e.id, 'motivo', e.motivo, 'resumen', e.resumen, 'documento', e.documento, 'creado_en', e.creado_en, 'atendida', e.atendida) from public.bot_escalaciones e where e.wa_id = ch.wa_id order by e.id desc limit 1))
      order by ch.sin_leer desc, ch.ultima_en desc) from ch), '[]'::jsonb),
    'sin_responder', coalesce((select jsonb_agg(jsonb_build_object('wa_id', sr.wa_id, 'nombre', nullif(sr.nombre, ''), 'desde', sr.desde, 'texto', sr.texto) order by sr.desde) from sr), '[]'::jsonb)) $$;

-- 6) Panel: conversación completa (persona, bot y equipo), en orden
create or replace function public.bot_panel_chat(p_wa text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('wa_id', p_wa,
    'mensajes', coalesce((select jsonb_agg(jsonb_build_object('rol', m.rol, 'texto', m.texto, 'humano', m.humano, 't', m.creado_en) order by m.id) from (select * from public.bot_mensajes where wa_id = p_wa order by id desc limit 1500) m), '[]'::jsonb),
    'correcciones', coalesce((select jsonb_agg(jsonb_build_object('antes', c.antes, 'despues', c.despues, 't', c.creado_en) order by c.id) from public.bot_correcciones c where c.wa_id = p_wa), '[]'::jsonb)) $$;

revoke all on function public.bot_buscar_programa(text,int), public.bot_corregir_datos(text,text,text,text), public.bot_panel_lista(), public.bot_panel_chat(text), public.bot_titulo(text) from public, anon, authenticated;
grant execute on function public.bot_buscar_programa(text,int), public.bot_corregir_datos(text,text,text,text), public.bot_panel_lista(), public.bot_panel_chat(text), public.bot_titulo(text) to service_role;
