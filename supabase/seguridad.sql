-- =====================================================================
-- Endurecimiento de seguridad — CheckList Auditorías
-- Ejecutar en Supabase: SQL Editor → pegar → Run.
-- Todo va en una transacción: si algo falla, no se aplica nada.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1) Quitar políticas "todo permitido".
--    En Postgres las políticas se SUMAN (OR): una política con `true`
--    anula todas las reglas específicas de la misma tabla. Hoy cualquier
--    usuario con sesión puede editar o borrar auditorías, respuestas,
--    firmas, evidencias e historial de cualquier persona.
-- ---------------------------------------------------------------------
drop policy if exists auditorias_authenticated on public.auditorias;
drop policy if exists respuestas_authenticated on public.respuestas;
drop policy if exists evidencias_authenticated on public.evidencias;
drop policy if exists firmas_authenticated     on public.firmas;
drop policy if exists historial_authenticated  on public.historial;

-- Duplicados en tareas. Las tareas solo las crea el trigger
-- trg_respuesta_tarea (SECURITY DEFINER), así que nadie necesita INSERT directo.
drop policy if exists tareas_insert                     on public.tareas;
drop policy if exists tareas_insert_authenticated       on public.tareas;
drop policy if exists tareas_select_authenticated       on public.tareas;
drop policy if exists tareas_update_involucrado_o_admin on public.tareas; -- tenía WITH CHECK (true)

-- usuarios: el perfil lo crea handle_new_user() al registrarse.
-- Con esta política alguien podía insertarse un segundo perfil con rol Administrador.
drop policy if exists usuarios_insert_self          on public.usuarios;
drop policy if exists usuarios_update_self_or_admin on public.usuarios; -- duplicado de usuarios_update

-- Firmas: solo el auditor de esa auditoría (o un admin)
drop policy if exists firmas_insert on public.firmas;
create policy firmas_insert on public.firmas for insert to authenticated
 with check (exists (select 1 from public.auditorias a
                     where a.id = firmas.auditoria_id
                       and (a.auditor_id = public.current_usuario_id() or public.is_admin())));

-- ---------------------------------------------------------------------
-- 2) Flujo de tareas validado en el servidor.
--    Antes, el responsable podía marcar su propia tarea como "aprobada"
--    desde la consola del navegador.
-- ---------------------------------------------------------------------
create or replace function public.validar_cambio_tarea()
returns trigger language plpgsql set search_path = public as $$
declare yo uuid := public.current_usuario_id();
begin
  if auth.uid() is null or public.is_admin() then return new; end if;

  if new.respuesta_id   is distinct from old.respuesta_id
  or new.responsable_id is distinct from old.responsable_id
  or new.revisor_id     is distinct from old.revisor_id
  or new.fecha_creacion is distinct from old.fecha_creacion then
    raise exception 'No tienes permiso para reasignar una tarea.' using errcode = '42501';
  end if;

  -- Responsable: abierta/rechazada → ejecutada (no puede moverse su propio plazo)
  if old.estado in ('abierta','rechazada') and new.estado = 'ejecutada'
     and old.responsable_id = yo
     and new.fecha_limite_resolver is not distinct from old.fecha_limite_resolver then
    return new;
  end if;

  -- Revisor: ejecutada → aprobada/rechazada
  if old.estado = 'ejecutada' and new.estado in ('aprobada','rechazada')
     and old.revisor_id = yo
     and new.comentario_ejecucion is not distinct from old.comentario_ejecucion then
    return new;
  end if;

  raise exception 'Cambio no permitido en la tarea (% → %).', old.estado, new.estado using errcode = '42501';
end $$;

drop trigger if exists trg_validar_cambio_tarea on public.tareas;
create trigger trg_validar_cambio_tarea before update on public.tareas
 for each row execute function public.validar_cambio_tarea();

-- ---------------------------------------------------------------------
-- 3) Correos de los usuarios: cualquiera con sesión podía listarlos.
--    Se mantiene visible el nombre (la app lo muestra en las tareas),
--    pero la columna `correo` deja de ser legible desde la app.
-- ---------------------------------------------------------------------
revoke select on public.usuarios from authenticated, anon;
grant select (id, auth_user_id, nombre, rol, activo, fecha_creacion, sucursal_centro, puesto)
  on public.usuarios to authenticated;

-- ---------------------------------------------------------------------
-- 4) Fotos (Storage). Hoy el bucket es PÚBLICO y además permite subir
--    archivos SIN iniciar sesión, de cualquier tipo y tamaño.
--    Las fotos que ya se subieron siguen viéndose (usan enlaces firmados).
-- ---------------------------------------------------------------------
drop policy if exists "public upload evidencias" on storage.objects;
drop policy if exists "public read evidencias"   on storage.objects;
drop policy if exists evidencias_storage_read    on storage.objects;
-- Se conservan evidencias_storage_insert y evidencias_storage_select (solo usuarios con sesión)

update storage.buckets
   set public = false,
       file_size_limit = 10485760, -- 10 MB
       allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic','image/heif']
 where id = 'evidencias';

-- ---------------------------------------------------------------------
-- 5) Funciones auxiliares: que no las pueda llamar alguien sin sesión.
-- ---------------------------------------------------------------------
revoke execute on function public.current_rol(), public.current_usuario_id(), public.directorio_usuarios(),
                           public.is_admin(), public.is_administrador()
  from public, anon;
grant execute on function public.current_rol(), public.current_usuario_id(), public.directorio_usuarios(),
                          public.is_admin(), public.is_administrador()
  to authenticated;

commit;

-- =====================================================================
-- Pasos que se hacen en el panel de Supabase (no con SQL):
--  • Authentication → Sign In / Providers → Email → desactivar "Allow new users to sign up"
--    (los usuarios se invitan desde Authentication → Users → Invite).
--  • Authentication → Attack Protection → activar "Leaked password protection".
-- =====================================================================
