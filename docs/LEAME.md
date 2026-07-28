# Instalación y actualización de Beacon AF ISCIII con Podman rootless

Esta guía describe el despliegue institucional de Beacon v2 AF de ISCIII-CIBER mediante Podman rootless.

Se utiliza tanto para una instalación nueva como para actualizar o recrear los contenedores conservando los datos persistentes existentes.

El stack incluye:

- Beacon API.
- Admin UI.
- MongoDB.
- Mongo Express.
- Keycloak.
- PostgreSQL para Keycloak.
- Template UI.
- Apache HTTP Server como reverse proxy.

La ingesta de datasets y variantes se realiza mediante `impact-tools`, instalado fuera de este stack. El despliegue no incluye un contenedor `ri-tools`.

`deploy/fix_permissions.sh` prepara los bind mounts, ownership, permisos, ACL y etiquetas SELinux necesarios antes de arrancar los contenedores.

## Índice

- [Requisitos](#requisitos)
- [Estructura de la instalación](#estructura-de-la-instalación)
- [Preparar directorios del host](#preparar-directorios-del-host)
- [Obtener o actualizar el código](#obtener-o-actualizar-el-código)
- [Configurar `.env`](#configurar-env)
- [Certificados y TLS](#certificados-y-tls)
- [Backup antes de actualizar](#backup-antes-de-actualizar)
- [Preparar permisos y SELinux](#preparar-permisos-y-selinux)
- [Construir y arrancar el stack](#construir-y-arrancar-el-stack)
- [Gestión de usuarios administrativos](#gestión-de-usuarios-administrativos)
- [Comprobaciones posteriores](#comprobaciones-posteriores)
- [Actualizar el despliegue](#actualizar-el-despliegue)
- [Rollback](#rollback)
- [Reparar permisos](#reparar-permisos)
- [Operaciones útiles](#operaciones-útiles)
- [Troubleshooting](#troubleshooting)

## Requisitos

El despliegue utiliza:

- Podman rootless ejecutado por un usuario normal.
- `podman compose` o `podman-compose`.
- Git.
- `curl`.
- `setfacl`.
- `fuse-overlayfs`.
- SELinux configurado por el sistema.
- Rangos `subuid` y `subgid` asignados al usuario que ejecuta Podman.
- Acceso a los registros de imágenes definidos en `.env`.

Comprueba que Podman funciona sin privilegios:

```bash
podman info
podman ps
```

No ejecutes `podman compose` ni `deploy/fix_permissions.sh` con `sudo`.

El usuario que ejecuta Podman debe ser siempre el mismo usuario que gestiona la instalación.

Los ejemplos de esta guía utilizan:

```text
/opt/containers_apps/beacon/beacon2-pi-api
```

Las rutas reales se configuran en `.env`.

## Estructura de la instalación

El código se mantiene separado de los datos persistentes, certificados y logs.

```text
${APP_ROOT}/
├── adminui/
├── beacon/
├── conf/
├── deploy/
├── docs/
│   └── LEAME.md
├── template-ui/
├── docker-compose.yml
├── .env
└── .env.example
```

Los datos persistentes se almacenan fuera del repositorio:

```text
${BIND_ROOT}/
├── etc/
│   └── certs/
└── runtime/
    ├── admin-ui/
    │   └── db.sqlite3
    ├── mongo/
    │   ├── db/
    │   ├── configdb/
    │   └── caseLevelData/
    └── postgres/
        └── data/
```

Los logs se almacenan en:

```text
${APP_LOG_DIR}/
├── beacon.log
├── mongod.log
└── postgres/

${APACHE_LOG_DIR}/
```

En la instalación validada:

```dotenv
APP_ROOT=/opt/containers_apps/beacon/beacon2-pi-api
BIND_ROOT=/srv/containers/bind/beacon
APP_LOG_DIR=/var/log/local/beacon/apps
APACHE_LOG_DIR=/var/log/local/beacon/apache
```

Los datos persistentes, certificados, logs y secretos no deben añadirse a Git.

## Preparar directorios del host

Los directorios padre deben existir y ser accesibles por el usuario que ejecuta Podman.

Si el usuario no puede crear rutas en `/srv/containers` o `/var/log/local`, deben ser creadas previamente por sistemas:

```bash
sudo mkdir -p /srv/containers/bind/beacon
sudo mkdir -p /var/log/local/beacon/apps
sudo mkdir -p /var/log/local/beacon/apache

sudo chown -R _USER-RUNNING-PODMAN_:_USER-RUNNING-PODMAN_ \
  /srv/containers/bind/beacon \
  /var/log/local/beacon
```

No es necesario crear manualmente todos los subdirectorios internos.

`deploy/fix_permissions.sh` crea las rutas necesarias y aplica los UIDs, GIDs y etiquetas correspondientes.

Comprueba el almacenamiento rootless utilizado por Podman:

```bash
podman info --format '{{.Store.GraphRoot}}'
```

En `dcontainers00` se utiliza:

```text
/srv/containers/storage/bioinfo
```

## Obtener o actualizar el código

### Instalación nueva

```bash
cd /opt/containers_apps/beacon

git clone \
  https://github.com/BU-ISCIII/beacon2-pi-api.git

cd beacon2-pi-api
```

### Instalación existente

Entra en el repositorio con el mismo usuario que ejecuta Podman:

```bash
cd /opt/containers_apps/beacon/beacon2-pi-api

git status
git fetch --all --prune
```

No actualices el código mientras existan cambios locales sin revisar.

Para actualizar una rama ya configurada:

```bash
git checkout main
git pull --ff-only
```

## Configurar `.env`

Si `.env` no existe, créalo a partir de la plantilla:

```bash
cp .env.example .env
chmod 0600 .env
```

Edita el fichero:

```bash
nano .env
```

`.env` contiene:

- rutas del despliegue;
- nombres de contenedores;
- imágenes y versiones;
- puertos publicados;
- hostnames públicos;
- credenciales de MongoDB;
- credenciales de PostgreSQL;
- credenciales administrativas de Keycloak;
- `SECRET_KEY` de Django;
- UIDs y GIDs internos de los servicios.

El fichero contiene secretos y está excluido mediante `.gitignore`.

No añadas contraseñas reales a `.env.example`.

Cuando se actualice el repositorio, compara la plantilla con el fichero local:

```bash
diff -u .env.example .env
```

No copies directamente `.env.example` sobre una configuración existente.

## Certificados y TLS

En este despliegue **el tráfico interno entre contenedores va en claro**:

- Beacon API sirve HTTP en el puerto 5050. Esta versión del código no implementa TLS: `beacon/__main__.py` levanta el `TCPSite` sin `ssl_context`, y las variables `beacon_server_crt` y `beacon_server_key` de `beacon/conf/conf.py` no las lee nadie.
- MongoDB no utiliza TLS. La sección `net.tls` de `mongod.conf` está comentada.
- Apache habla con Beacon mediante `ProxyPass http://beaconprod:5050/api`.

`beacon/conf/conf.py` debe declarar el `uri` con el mismo esquema:

```python
uri = 'http://beaconprod:5050'
```

Esto es obligatorio: aiohttp construye `request.url` a partir de la conexión TCP y la compara con `config.uri`. Si ambos no coinciden, la API rechaza las peticiones.

Los ficheros siguientes se siguen montando por compatibilidad, pero actualmente no se utilizan:

```text
${BIND_ROOT}/etc/certs/beacon_server.crt
${BIND_ROOT}/etc/certs/beacon_server.key
```

**Pendiente:** certificados institucionales y terminación TLS en Apache para acceso exterior.

## Backup antes de actualizar

Haz backup antes de cambiar de versión, reconstruir el stack o modificar la configuración persistente.

Carga las variables del despliegue:

```bash
set -a
source .env
set +a
```

Crea el directorio de backup:

```bash
BACKUP_DIR="${HOME}/beacon_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${BACKUP_DIR}"
```

Detén el stack para obtener una copia consistente:

```bash
podman compose down
```

Guarda la configuración local:

```bash
cp .env "${BACKUP_DIR}/env"
cp conf/beacon_apache_reverse_proxy.conf \
  "${BACKUP_DIR}/beacon_apache_reverse_proxy.conf"
cp beacon/conf/conf.py "${BACKUP_DIR}/conf.py"
cp beacon/connections/mongo/conf.py \
  "${BACKUP_DIR}/mongo_conf.py"
```

`beacon/conf/conf.py` es configuración local editable desde Admin UI: cada guardado reescribe el fichero.

Guarda los datos persistentes:

```bash
tar -C "${BIND_ROOT}" \
  -cpf "${BACKUP_DIR}/beacon_bind_data.tar" .
```

Opcionalmente, guarda los logs:

```bash
tar -C "$(dirname "${APP_LOG_DIR}")" \
  -cpf "${BACKUP_DIR}/beacon_logs.tar" \
  "$(basename "${APP_LOG_DIR}")"
```

Guarda la revisión del código:

```bash
git rev-parse HEAD > "${BACKUP_DIR}/git_commit.txt"
git status --short > "${BACKUP_DIR}/git_status.txt"
```

Comprueba el backup:

```bash
ls -lh "${BACKUP_DIR}"
```

## Preparar permisos y SELinux

Los contenedores ejecutan procesos con distintos UIDs dentro del namespace rootless.

No se depende de los modificadores automáticos `:Z`, `:z` o `:U` para gestionar los bind mounts.

La preparación se realiza mediante:

```text
deploy/fix_permissions.sh
```

El script:

- lee `.env`;
- comprueba que los contenedores estén detenidos;
- crea las rutas persistentes necesarias;
- configura los datos de MongoDB;
- configura los datos de PostgreSQL;
- configura la base SQLite de Admin UI;
- prepara los logs;
- configura los certificados;
- aplica etiquetas SELinux `container_file_t:s0`;
- elimina niveles MCS privados residuales;
- aplica ACL para que Admin UI pueda modificar la configuración de Beacon.

Admin UI necesita acceso de escritura sobre:

```text
beacon/conf/conf.py
beacon/conf/datasets/
beacon/connections/mongo/conf.py
beacon/permissions/datasets/
beacon/auth/idp_providers/
beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/
```

El ownership del código se mantiene en el usuario del host. El acceso del UID interno de Admin UI se concede mediante ACL.

**Importante:** las ACL se pierden al reemplazar un fichero. `sed -i`, `git checkout`, `git switch` y la mayoría de editores no modifican el fichero en su sitio: escriben uno nuevo y lo renombran encima, y la ACL se va con el original. Tras editar a mano cualquiera de las rutas anteriores, reejecuta el script o restaura la ACL del fichero concreto:

```bash
set -a
source .env
set +a

podman unshare setfacl -m "u:${ADMIN_UI_UID}:rw" \
  "${APP_ROOT}/beacon/conf/conf.py"
```

Ejecuta:

```bash
podman compose down

chmod +x deploy/fix_permissions.sh
./deploy/fix_permissions.sh
```

El script se detendrá si detecta algún contenedor del stack activo.

Al finalizar muestra los modos y propietarios efectivos de las rutas principales.

## Construir y arrancar el stack

Valida primero la configuración de Compose:

```bash
podman compose config >/dev/null \
  && echo "Compose OK"
```

Comprueba también posibles errores de formato:

```bash
git diff --check
```

Construye las imágenes locales:

```bash
podman compose build
```

También pueden construirse individualmente:

```bash
podman compose build beaconprod
podman compose build admin-ui
podman compose build template-ui
```

Arranca el stack:

```bash
podman compose up -d
```

Comprueba los contenedores:

```bash
podman ps -a --format \
  "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Deben aparecer:

```text
beaconprod
admin-ui
idp
idp-db
mongoprod
mongo-express
template-ui
apache-beacon
```

Los nombres concretos se obtienen de `.env`.

## Gestión de usuarios administrativos

Los usuarios administrativos se gestionan de forma independiente en Admin UI, Keycloak y MongoDB.

Antes de utilizar los comandos de esta sección, carga las variables del despliegue:

```bash
set -a
source .env
set +a
```

### Admin UI

Para crear un superusuario de Django:

```bash
podman exec -it "${ADMIN_UI_CONTAINER}" \
  python manage.py createsuperuser --skip-checks
```

El comando solicita de forma interactiva el nombre de usuario, el correo electrónico y la contraseña.

Los usuarios existentes pueden consultarse desde el panel de administración:

```text
${PUBLIC_SCHEME}://${PUBLIC_HOST}:${PUBLIC_PORT}/admin-ui/admin/
```

### Keycloak

El administrador inicial de Keycloak se define en `.env` antes del primer arranque:

```dotenv
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=<contraseña-segura>
```

Estas variables crean el administrador únicamente durante la inicialización. Si PostgreSQL ya contiene una instalación de Keycloak, modificar sus valores en `.env` no cambia automáticamente la contraseña del usuario existente.

Los usuarios adicionales, sus contraseñas y sus roles deben gestionarse desde la consola de administración:

```text
${PUBLIC_SCHEME}://${PUBLIC_HOST}:${PUBLIC_PORT}${KEYCLOAK_RELATIVE_PATH}/admin/
```

Para conceder permisos administrativos, asigna al usuario los roles correspondientes desde la sección **Role mapping** de Keycloak.

### MongoDB

El usuario administrador inicial de MongoDB se configura en `.env`:

```dotenv
MONGO_ROOT_USERNAME=root
MONGO_ROOT_PASSWORD=<contraseña-segura>
```

Estas variables solo crean el usuario cuando se inicializa una base de datos vacía. Modificarlas después no actualiza las credenciales almacenadas en una instalación existente.

Para acceder a la consola administrativa:

```bash
podman exec -it "${MONGO_CONTAINER}" \
  mongosh \
  -u "${MONGO_ROOT_USERNAME}" \
  -p \  # -p "${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase "${MONGO_AUTH_SOURCE}"
```

El parámetro `-p` solicita la contraseña de forma interactiva y evita incluirla directamente en el historial de la terminal.

### Mongo Express

Mongo Express no mantiene usuarios propios. Su acceso web utiliza autenticación básica configurada mediante variables de entorno.

```dotenv
MONGO_EXPRESS_USERNAME=<usuario>
MONGO_EXPRESS_PASSWORD=<contraseña-segura>
```

Para comprobar el acceso:

```bash
curl -s -u "${MONGO_EXPRESS_USERNAME}:${MONGO_EXPRESS_PASSWORD}" \
  -o /dev/null -w "HTTP %{http_code}\n" \
  "${PUBLIC_SCHEME}://${PUBLIC_HOST}:${PUBLIC_PORT}/mongo-express/"
```

No deben utilizarse las credenciales predeterminadas `admin:pass`. 

## Comprobaciones posteriores

### Estado de los contenedores

```bash
podman compose ps
```

Ningún contenedor debe permanecer en estado `Restarting` o `Exited`.

### Comprobar que todos los endpoints funcionan

Desde la raíz del repositorio, ejecuta:

```bash
chmod +x deploy/check_endpoints.sh
./deploy/check_endpoints.sh
```

El script comprueba el acceso a Template UI, Beacon API, Keycloak, Admin UI y Mongo Express. Todos los endpoints deben devolver OK.

### Template UI

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  http://beaconaf-isciiiciber.isciiides.es:8443/
```

Resultado esperado:

```text
HTTP 200
```

### Beacon API

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  http://apibeacon-isciiiciber.isciiides.es:8443/api/info
```

Resultado esperado:

```text
HTTP 200
```

También debe responder desde el hostname principal:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  http://beaconaf-isciiiciber.isciiides.es:8443/api/info
```

### Keycloak

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  http://beaconaf-isciiiciber.isciiides.es:8443/auth/
```

Resultado esperado:

```text
HTTP 200
```

### Admin UI

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  http://beaconaf-isciiiciber.isciiides.es:8443/admin-ui/
```

Puede devolver:

```text
HTTP 302
```

si redirige al login.

Comprueba también desde la interfaz que es posible guardar una configuración.

### Mongo Express

Sin autenticación:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  http://beaconaf-isciiiciber.isciiides.es:8443/mongo-express/
```

Resultado esperado:

```text
HTTP 401
```

Con las credenciales configuradas debe devolver:

```text
HTTP 200
```

### Migraciones de Admin UI

Las migraciones se ejecutan automáticamente al arrancar.

Para comprobarlas manualmente:

```bash
podman exec admin-ui \
  python manage.py migrate --skip-checks
```

No ejecutes `manage.py` desde el host salvo que exista un entorno Python local con Django y todas las dependencias.

### Datos de MongoDB

Comprueba que MongoDB responde:

```bash
podman exec mongoprod \
  mongosh --quiet \
  -u "${MONGO_ROOT_USERNAME}" \
  -p "${MONGO_ROOT_PASSWORD}" \
  --authenticationDatabase "${MONGO_AUTH_SOURCE}" \
  --eval 'db.adminCommand({ping: 1})'
```

## Actualizar el despliegue

Guarda primero un backup siguiendo la sección anterior.

Actualiza el código:

```bash
cd /opt/containers_apps/beacon/beacon2-pi-api

git fetch --all --prune
git checkout main
git pull --ff-only
```

Revisa si existen variables nuevas:

```bash
diff -u .env.example .env
```

Con los contenedores detenidos, reaplica permisos:

```bash
./deploy/fix_permissions.sh
```

Reconstruye las imágenes:

```bash
podman compose build
```

Arranca:

```bash
podman compose up -d
```

Repite las comprobaciones posteriores.

## Rollback

Si la actualización falla, utiliza el backup realizado previamente.

Detén el stack:

```bash
podman compose down
```

Recupera el commit anterior:

```bash
PREVIOUS_COMMIT="$(cat "${BACKUP_DIR}/git_commit.txt")"
git checkout --detach "${PREVIOUS_COMMIT}"
```

Restaura `.env`:

```bash
cp "${BACKUP_DIR}/env" .env
chmod 0600 .env
```

Si es necesario restaurar también los datos persistentes:

```bash
set -a
source .env
set +a

rm -rf "${BIND_ROOT:?}/"*
tar -C "${BIND_ROOT}" \
  -xpf "${BACKUP_DIR}/beacon_bind_data.tar"
```

Repara permisos:

```bash
./deploy/fix_permissions.sh
```

Reconstruye y arranca:

```bash
podman compose build
podman compose up -d
```

Comprueba contenedores y endpoints.

Mantén la instalación en este commit mientras se investiga el problema. Una vez resuelta la causa del fallo y cuando quieras volver a la versión actual:

```bash
git checkout main
git pull --ff-only
```

## Reparar permisos

Ejecuta `fix_permissions.sh` cuando:

- se haya recreado o migrado el almacenamiento persistente;
- se hayan restaurado datos desde un backup;
- hayan cambiado propietarios en el host;
- hayan cambiado los UIDs o GIDs definidos en `.env`;
- Admin UI no pueda guardar configuraciones (error en botón "save");
- un contenedor falle con `Permission denied`;
- se hayan perdido o modificado las etiquetas SELinux;
- se haya movido la instalación a otra ruta.

Procedimiento:

```bash
podman compose down
./deploy/fix_permissions.sh
podman compose up -d
```

Comprueba una ruta dentro del namespace:

```bash
podman unshare stat -c '%a %u:%g %n' <ruta>
```

Comprueba su etiqueta SELinux:

```bash
ls -ldZ <ruta>
```

La etiqueta esperada en los bind mounts es:

```text
container_file_t:s0
```

No deben conservar niveles privados como:

```text
s0:c123,c456
```

Comprueba la ACL de Admin UI:

```bash
set -a
source .env
set +a

podman unshare getfacl \
  "${APP_ROOT}/beacon/conf/conf.py"
```

## Operaciones útiles

### Ver estado

```bash
podman compose ps
podman ps -a
```

### Ver logs del stack

```bash
podman compose logs --tail 200
```

### Ver logs de un servicio

```bash
podman compose logs --tail 200 beaconprod
podman compose logs --tail 200 admin-ui
podman compose logs --tail 200 db
podman compose logs --tail 200 idp
podman compose logs --tail 200 apache-beacon
```

### Seguir logs en tiempo real

```bash
podman logs -f beaconprod
```

### Reiniciar un servicio

```bash
podman compose restart <servicio>
```

### Detener el stack conservando los datos

```bash
podman compose down
```

### Arrancar el stack

```bash
podman compose up -d
```

### Reconstruir una imagen

```bash
podman compose build <servicio>
podman compose up -d <servicio>
```

### Consultar uso de almacenamiento

```bash
podman system df
podman info --format '{{.Store.GraphRoot}}'
```

### Restablecer permisos de un servicio concreto

Detén el servicio, repara sus permisos y vuelve a arrancarlo:

```bash
podman compose stop <servicio>
./deploy/fix_permissions.sh <servicio>
podman compose up -d <servicio>
```

Servicios admitidos:

- `db`(mongodb)
- `idp-db` (postgresql)
- `admin-ui`
- `beaconprod`
- `apache-beacon`
- `template-ui`

Para reparar todo el despliegue:
```bash
podman compose down
./deploy/fix_permissions.sh
podman compose up -d
```

## Troubleshooting

### `Permission denied` en un bind mount

Detén el stack y reaplica:

```bash
podman compose down
./deploy/fix_permissions.sh
podman compose up -d
```

### Gestionar usuarios administrativos

Consulta la sección [Gestión de usuarios administrativos](#gestión-de-usuarios-administrativos).

### Admin UI no puede guardar cambios

Un error como:

```text
PermissionError: [Errno 13] Permission denied
```

sobre un fichero en `/home/app/web/beacon/` indica que falta la ACL del UID interno de Admin UI.

Repara los permisos:

```bash
podman compose stop admin-ui
./deploy/fix_permissions.sh admin-ui
podman compose up -d admin-ui
```

### MongoDB no arranca por ownership

```bash
podman compose down
./deploy/fix_permissions.sh
podman compose up -d db

podman logs mongoprod 2>&1 | tail -100
```

### PostgreSQL no puede modificar sus datos

El servicio `idp-db` no debe declarar:

```yaml
user: "999:999"
```

Su entrypoint necesita arrancar como root del namespace.

Después de corregir Compose:

```bash
podman compose down
./deploy/fix_permissions.sh
podman compose up -d idp-db idp
```

### Apache devuelve `502 Bad Gateway`

Comprueba los servicios de destino:

```bash
podman ps -a

podman logs beaconprod 2>&1 | tail -100
podman logs template-ui 2>&1 | tail -100
podman logs admin-ui 2>&1 | tail -100
podman logs apache-beacon 2>&1 | tail -100
```

### El Compose contiene una variable sin definir

```bash
podman compose config
```

Revisa `.env` y compáralo con:

```bash
diff -u .env.example .env
```

### Ingesta de datasets y variantes

La ingesta no se ejecuta desde este Compose.

Se utiliza la instalación independiente de `impact-tools`:

```bash
impact-tools beacon ingest dataset ...
impact-tools beacon ingest variants ...
```

La documentación específica de los formatos de entrada y comandos se mantiene en el repositorio de `impact-tools`.
