-- =====================================================================
-- Ajustes KNO
--  1) Borrar sucursales de KSA y KSC (con todas sus auditorías) y KN14
--  2) Preguntas del Jefe Administrativo → Jefe Operativo
--  3) Tareas compartidas: si hay varias personas con el mismo puesto en la
--     sucursal (p. ej. dos gerentes), la tarea se asigna a todas
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1) Borrado de sucursales
-- ---------------------------------------------------------------------
create temporary table _suc_borrar on commit drop as
 select centro from public.sucursales where razon_social_clave in ('KSA','KSC') or centro = 'KN14';
create temporary table _aud_borrar on commit drop as
 select id from public.auditorias where sucursal_centro in (select centro from _suc_borrar);

delete from public.evidencias where tarea_id in (
  select t.id from public.tareas t join public.respuestas r on r.id = t.respuesta_id
   where r.auditoria_id in (select id from _aud_borrar));
delete from public.tareas where respuesta_id in (
  select id from public.respuestas where auditoria_id in (select id from _aud_borrar));
delete from public.respuestas where auditoria_id in (select id from _aud_borrar);
delete from public.firmas     where auditoria_id in (select id from _aud_borrar);
delete from public.historial  where auditoria_id in (select id from _aud_borrar);
delete from public.auditorias where id in (select id from _aud_borrar);

-- Jose Carlos Hernandez (gerente de KN14): se conserva desactivado y sin sucursal
update public.usuarios set sucursal_centro = null, activo = false
 where sucursal_centro in (select centro from _suc_borrar);

delete from public.sucursales where centro in (select centro from _suc_borrar);
delete from public.razones_sociales where clave in ('KSA','KSC');

-- ---------------------------------------------------------------------
-- 2) Preguntas del Jefe de Almacén Administrativo → Operativo
-- ---------------------------------------------------------------------
update public.puntos set responsable_rol = 'Jefe de Almacen Operativo'
 where responsable_rol = 'Jefe de Almacen Administrativo';

-- ---------------------------------------------------------------------
-- 3) Tareas con varios responsables
--    responsable_id se conserva (primer responsable) por compatibilidad;
--    `responsables` tiene a todas las personas que pueden resolverla.
-- ---------------------------------------------------------------------
alter table public.tareas add column if not exists responsables uuid[] not null default '{}';
create index if not exists tareas_responsables_idx on public.tareas using gin (responsables);

create or replace function public.responsables_de(p_puesto text, p_sucursal text)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(
    (select array_agg(id order by nombre) from usuarios
      where puesto = p_puesto and coalesce(activo, true) and sucursal_centro = p_sucursal),
    (select array_agg(id order by nombre) from usuarios
      where puesto = p_puesto and coalesce(activo, true) and sucursal_centro is null),
    '{}'::uuid[])
$$;
revoke execute on function public.responsables_de(text, text) from public, anon, authenticated;

create or replace function public.fn_respuesta_generar_tarea()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  p puntos%rowtype;
  a auditorias%rowtype;
  resps uuid[];
begin
  select * into p from puntos where id = new.punto_id;
  select * into a from auditorias where id = new.auditoria_id;

  if new.es_no_conforme and p.genera_tarea then
    resps := responsables_de(p.responsable_rol, a.sucursal_centro);

    insert into tareas (respuesta_id, responsable_id, responsables, revisor_id, estado, fecha_creacion, fecha_limite_resolver)
    values (new.id, resps[1], resps, a.auditor_id, 'abierta', now(), now() + (p.plazo_resolver_dias || ' days')::interval);

    insert into historial (auditoria_id, usuario_nombre, accion)
    values (a.id, 'Sistema', 'Tarea generada automáticamente: '||p.pregunta);
  end if;
  return new;
end;
$$;

-- Tareas que ya existen: completar responsables (incluye las que habían quedado sin nadie)
update public.tareas t
   set responsables = x.resps, responsable_id = coalesce(t.responsable_id, x.resps[1])
  from (select t2.id, responsables_de(p.responsable_rol, a.sucursal_centro) resps
          from public.tareas t2
          join public.respuestas r on r.id = t2.respuesta_id
          join public.puntos p     on p.id = r.punto_id
          join public.auditorias a on a.id = r.auditoria_id) x
 where x.id = t.id and t.responsables = '{}';

-- Permisos: cualquiera de los responsables puede enviar la tarea a aprobación
drop policy if exists tareas_update on public.tareas;
create policy tareas_update on public.tareas for update to authenticated
 using      (responsable_id = current_usuario_id() or current_usuario_id() = any(responsables)
             or revisor_id = current_usuario_id() or is_admin())
 with check (responsable_id = current_usuario_id() or current_usuario_id() = any(responsables)
             or revisor_id = current_usuario_id() or is_admin());

create or replace function public.validar_cambio_tarea()
returns trigger language plpgsql set search_path = public as $$
declare yo uuid := public.current_usuario_id();
begin
  if auth.uid() is null or public.is_admin() then return new; end if;

  if new.respuesta_id   is distinct from old.respuesta_id
  or new.responsable_id is distinct from old.responsable_id
  or new.responsables   is distinct from old.responsables
  or new.revisor_id     is distinct from old.revisor_id
  or new.fecha_creacion is distinct from old.fecha_creacion then
    raise exception 'No tienes permiso para reasignar una tarea.' using errcode = '42501';
  end if;

  if old.estado in ('abierta','rechazada') and new.estado = 'ejecutada'
     and (old.responsable_id = yo or yo = any(old.responsables))
     and new.fecha_limite_resolver is not distinct from old.fecha_limite_resolver then
    return new;
  end if;

  if old.estado = 'ejecutada' and new.estado in ('aprobada','rechazada')
     and old.revisor_id = yo
     and new.comentario_ejecucion is not distinct from old.comentario_ejecucion then
    return new;
  end if;

  raise exception 'Cambio no permitido en la tarea (% → %).', old.estado, new.estado using errcode = '42501';
end $$;

commit;

-- Nota: las 2 fotos de las auditorías borradas siguen en Storage, carpeta
-- evidencias/9c2ab826-edfd-4462-99ac-25db4a3e41c9/ — se borran desde el panel (Storage).
