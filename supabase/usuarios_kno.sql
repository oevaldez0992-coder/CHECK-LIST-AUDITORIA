-- =====================================================================
-- Alta de auditores, gerentes y jefes de almacén de KNO
-- Los correos se guardan en minúsculas (así los guarda Supabase Auth).
-- Si el usuario ya existe (mismo correo) se actualizan nombre, puesto y sucursal.
-- =====================================================================

-- Auditores: todas las sucursales de KNO (sin sucursal fija)
update public.usuarios set nombre = 'Fernando Guerrero', puesto = 'Auditor', sucursal_centro = null
 where correo = 'fernando.guerrero@kuroda.com';
update public.usuarios set nombre = 'Oscar Amavizca', puesto = 'Auditor', sucursal_centro = null
 where correo = 'oamavizca@kuroda.com';   -- conserva su rol de Administrador

insert into public.usuarios (nombre, correo, rol, puesto, sucursal_centro, activo) values
 -- Gerentes
 ('Karely Bueno',          'karely.bueno@kuroda.com',          'Usuario', 'Gerente', 'KN00', true),
 ('Rodolfo Cervantes',     'rcervantes@kuroda.com',            'Usuario', 'Gerente', 'KN01', true),
 ('Antonio Perez',         'antonio.perez@kuroda.com',         'Usuario', 'Gerente', 'KN01', true),
 ('Adriana Felix',         'afelix@kuroda.com',                'Usuario', 'Gerente', 'KN03', true),
 ('Rosa Nely Salinas',     'rsalinas@kuroda.com',              'Usuario', 'Gerente', 'KN05', true),
 ('Iris Miramontes',       'imiramontes@kuroda.com',           'Usuario', 'Gerente', 'KN05', true),
 ('Wendy Lozano',          'wlozano@kuroda.com',               'Usuario', 'Gerente', 'KN07', true),
 ('Jose Carlos Hernandez', 'jose.hernandez@kuroda.com',        'Usuario', 'Gerente', 'KN14', true),
 ('Marcelo Armenta',       'marcelo.armenta@kuroda.com',       'Usuario', 'Gerente', 'KN16', true),
 ('Emmanuel Olivas',       'emmanuel.olivas@kuroda.com',       'Usuario', 'Gerente', 'KN17', true),
 ('Pablo Medina',          'pmedina@kuroda.com',               'Usuario', 'Gerente', 'KN18', true),
 ('Annel Becerra',         'annel.becerra@kuroda.com',         'Usuario', 'Gerente', 'KN19', true),
 ('Gustavo Navarro',       'gustavo.navarro@kuroda.com',       'Usuario', 'Gerente', 'KN21', true),
 -- Jefes de almacén (Jose Marina también cubre KN14, pero la tabla admite una sola sucursal)
 ('Jonathan Colon',        'surtido.20nov@kuroda.com',         'Usuario', 'Jefe de Almacen Operativo', 'KN00', true),
 ('Jose Marina',           'operativo.express@kuroda.com',     'Usuario', 'Jefe de Almacen Operativo', 'KN01', true),
 ('Gerardo Andrade',       'operativo.ensenada@kuroda.com',    'Usuario', 'Jefe de Almacen Operativo', 'KN03', true),
 ('Hector Lopez',          'operativo.kn05@kuroda.com',        'Usuario', 'Jefe de Almacen Operativo', 'KN05', true),
 ('Erick Garcia',          'egarcia@kuroda.com',               'Usuario', 'Jefe de Almacen Operativo', 'KN07', true),
 ('Jesus Gonzalez',        'almacen.cediskno@kuroda.com',      'Usuario', 'Jefe de Almacen Operativo', 'KN16', true),
 ('Adan Ayala',            'operativo.rosarito@kuroda.com',    'Usuario', 'Jefe de Almacen Operativo', 'KN17', true),
 ('Eduardo Garcia',        'almacen.mxlproyectos@kuroda.com',  'Usuario', 'Jefe de Almacen Operativo', 'KN18', true),
 ('Jesus Pulido',          'jaula.tecate@kuroda.com',          'Usuario', 'Jefe de Almacen Operativo', 'KN19', true),
 ('Viviana Barron',        'vbarron@kuroda.com',               'Usuario', 'Jefe de Almacen Operativo', 'KN21', true)
on conflict (correo) do update
 set nombre = excluded.nombre, puesto = excluded.puesto, sucursal_centro = excluded.sucursal_centro;

-- Al aceptar la invitación, la cuenta de acceso se enlaza con el perfil ya registrado
-- (antes, `on conflict do nothing` dejaba el perfil sin enlazar y la persona no podía entrar).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.usuarios (auth_user_id, nombre, correo, rol)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)), lower(new.email), 'Usuario')
  on conflict (correo) do update set auth_user_id = excluded.auth_user_id
   where public.usuarios.auth_user_id is null;
  return new;
end;
$$;
