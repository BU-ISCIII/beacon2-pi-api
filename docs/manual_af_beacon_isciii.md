# Manual de instalación de Beacon AF ISCIII

Este manual describe el despliegue completo de Beacon v2 AF en una VM Linux usando:

- `podman` rootless con compatibilidad Docker
- `podman compose`
- MongoDB con TLS
- Keycloak como IdP
- Apache como reverse proxy
- ri-tools para ingesta de datasets

El objetivo es que, al terminar, puedas validar de extremo a extremo:

1. arranque de todos los contenedores
2. ingesta de un VCF en MongoDB con ri-tools
3. registro de metadatos del dataset
4. reindex y extracción de filtering terms
5. consulta del dataset por la API
6. acceso por la template UI

## Alcance

Este documento se centra en el flujo que se ha validado en `dcontainers00`:

- `beaconprod`, `mongoprod`, `idp`, `idp-db`, `ri-tools`, `template-ui`, `apache-beacon` en contenedores
- MongoDB con TLS obligatorio
- Keycloak 18 con realm Beacon importado
- Apache como reverse proxy en el puerto 8443

## Arquitectura mínima

| Componente | Rol | Puerto |
|---|---|---|
| `beaconprod` | API Beacon v2 | `5050` (interno) |
| `mongoprod` | MongoDB con TLS, almacena variantes y metadatos | `27017` (interno) |
| `idp` | Keycloak 18 para autenticación | `8082` |
| `idp-db` | PostgreSQL para Keycloak | `5432` (interno) |
| `ri-tools` | Herramienta de ingesta de VCFs a MongoDB | — |
| `mongo-express` | UI web para inspeccionar MongoDB | `8081` |
| `template-ui` | Frontend Beacon | `3000` |
| `apache-beacon` | Reverse proxy HTTPS, expone API y UI | `8443` |

La URL pública para los usuarios es:

```
http://beaconaf-isciiiciber.isciiides.es:8443
```

## Preparación e instalación

### Sistema

- Linux RHEL/CentOS
- `podman`, `podman-compose` o `podman compose`
- `git`, `curl`, `jq`, `python3`

### Rutas

Se asume el repo y directorio de trabajo en `/opt/beacon/beacon2-pi-api-isciii`

### Certificados TLS

MongoDB exige TLS. Antes de arrancar nada, los certificados deben estar generados en :

```text
/opt/beacon/beacon2-pi-api-isciii/certs/
├── ca.crt
├── server.pem
├── client.pem
├── beacon_server.crt
└── beacon_server.key
```

Permisos:

```bash
chmod 644 certs/ca.crt certs/beacon_server.crt
chmod 600 certs/server.pem certs/client.pem certs/beacon_server.key
```

## Estructura y permisos correctos

Este bloque es importante. Si no queda así, aparecerán errores de `Permission denied` en cascada.

### Crear estructura de datos

```bash
mkdir -p beacon/connections/mongo/data/{db,configdb,caseLevelData}
mkdir -p postgres/data
mkdir -p /var/log/local/apps/beacon/{apache,ri-tools}
touch /var/log/local/apps/beacon/logs.log
touch /var/log/local/apps/beacon/mongod.log
```

### Permisos para Podman rootless

Los UIDs/GIDs internos varían por imagen. Averigua los correctos con:

​```bash
podman exec mongoprod id # 999
podman exec idp-db id # 999
podman exec beaconprod id # 10001
​```

```bash
podman unshare chown -R 999:999 beacon/connections/mongo/data
podman unshare chown -R 999:999 postgres/data
podman unshare chown -R 10001:10001 /var/log/local/apps/beacon
```

### SELinux: diferencia entre `:z` y `:Z`

En `docker-compose.yml` los volúmenes usan dos modos distintos según el caso:

- `:z` (minúscula) — etiqueta compartida entre contenedores. Úsalo para certificados que comparten `beaconprod`, `ri-tools` y `mongoprod`.
- `:Z` (mayúscula) — etiqueta exclusiva del contenedor. Si pones `:Z` en un cert compartido, otros contenedores no podrán leerlo.

Es una de las causas más difíciles de diagnosticar cuando aparece `Permission denied` aunque los permisos POSIX estén bien.

> Nota: existe también el modificador `:U` (mapeo automático de UID/GID al usuario del contenedor) que podría simplificar la asignación de permisos. Aún no está validado en el despliegue actual. 

## Configuración

### Fichero de configuración de Beacon

`beacon/conf/conf.py` — contiene los valores específicos de ISCIII:

```python
beacon_id = 'es.isciii-ciber.beacon'
beacon_name = 'ISCIII-CIBER Spain AF Beacon'
uri = 'https://beaconprod:5050'
alternative_url = 'http://beaconaf-isciiiciber.isciiides.es:8443'
org_id = 'ISCIII'
org_name = 'Instituto de Salud Carlos III'
org_contact_url = 'mailto:bioinformatica@isciii.es'
```

### Fichero de configuración de MongoDB

`beacon/connections/mongo/conf.py`:

```python
database_certificate = os.getenv('database_certificate', '/etc/beacon/certs/client.pem')
database_cafile = os.getenv('database_cafile', '/etc/beacon/certs/ca.crt')
```

`beacon/connections/mongo/mongod.conf`:

```yaml
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
storage:
  wiredTiger:
    engineConfig:
      cacheSizeGB: 1
net:
  port: 27017
  bindIp: 0.0.0.0
security:
  authorization: enabled
```

### ri-tools

`ri-tools/conf/conf.py`:

```python
csv_folder = './csv/'
entry_type='all'
only_process_reads_with_allele_frequency=True
populations_by_allele_counts=True
reference_genome='GRCh38'
datasetId='ISCIII_ES_WGSTRIO_3'
database_auth_source = 'admin'
```

### Parche TLS en ri-tools

La imagen `ghcr.io/ega-archive/beacon2-ri-tools-v2:2.0.6` no soporta TLS para conectar a MongoDB a través de `conf.py`. El script `genomicVariations_vcf.py` necesita un parche para pasar los flags TLS al `MongoClient`.

El parche está en `ri-tools/patches/genomicVariations_vcf.py` y se monta sobre el del contenedor con:

​```yaml
ri-tools:
  volumes:
    - /opt/beacon/beacon2-pi-api-isciii/ri-tools/patches/genomicVariations_vcf.py:/usr/src/app/genomicVariations_vcf.py:ro,z
    - /opt/beacon/beacon2-pi-api-isciii/certs/ca.crt:/etc/mongo/certs/ca.crt:ro,z
    - /opt/beacon/beacon2-pi-api-isciii/certs/client.pem:/etc/mongo/certs/client.pem:ro,z
​```

Sin este parche, la ingesta falla con `SSLHandshakeFailed`.

### Keycloak v18

`docker-compose.yml`:

```yaml
idp:
  image: quay.io/keycloak/keycloak:18.0.0
  command:
    - start-dev
    - --import-realm
  environment:
    - KEYCLOAK_ADMIN=admin
    - KEYCLOAK_ADMIN_PASSWORD=secret
    - KC_DB=postgres
    - KC_HOSTNAME_URL=http://172.20.10.47:8082
```

El realm `Beacon` se importa automáticamente desde `beacon/auth/realms/beacon-realm.json`

### Apache reverse proxy

`conf/beacon_apache_reverse_proxy.conf` — configuración del reverse proxy que enruta API y UI:

​```apache
# Apache reverse proxy config for Beacon v2 AF - ISCIII
<VirtualHost *:8080>
    ServerName beaconaf-isciiiciber.isciiides.es
    ServerAlias apibeacon-isciiiciber.isciiides.es
    
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "http"
    RequestHeader set X-Forwarded-Port "8443"
    SSLProxyEngine On
    SSLProxyVerify none
    SSLProxyCheckPeerCN off
    SSLProxyCheckPeerName off
    ProxyPass        /api https://beaconprod:5050/api
    ProxyPassReverse /api https://beaconprod:5050/api
    ProxyPass        / http://template-ui:3000/
    ProxyPassReverse / http://template-ui:3000/
    ErrorLog  /var/log/httpd/beacon-af.error.log
    CustomLog /var/log/httpd/beacon-af.access.log combined
</VirtualHost>
​```

El contenedor `apache-beacon` monta este fichero como `/etc/httpd/conf.d/beacon.conf` y los logs en `/var/log/local/apps/beacon/apache/`.

## Construcción de imágenes

Las imágenes locales (`beaconprod`, `template-ui`) se construyen automáticamente la primera vez que se arranca el stack, gracias al campo `build:` en `docker-compose.yml`. El resto se descargan de los registries (`mongo`, `keycloak`, `postgres`, `httpd`, `ri-tools`, `mongo-express`).

Si necesitas forzar una reconstrucción tras cambiar el `Dockerfile`:

​```bash
podman compose build beaconprod template-ui
​```

## Arranque correcto

Orden validado:

```bash
podman compose up -d idp-db idp
podman compose up -d mongo
podman compose up -d beaconprod
podman compose up -d ri-tools template-ui apache-beacon mongo-express
```

Comprueba:

```bash
podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Deberías ver:

- `idp-db`
- `idp`
- `mongoprod`
- `beaconprod`
- `ri-tools`
- `template-ui`
- `apache-beacon`
- `mongo-express`

## Validaciones iniciales

### Comprobar `mongoprod`

```bash
podman logs --tail=50 mongoprod
```

Debe llegar a:

```text
Waiting for connections
```

Y debe aceptar conexiones TLS:

```bash
podman exec mongoprod mongosh \
  --tls --tlsCertificateKeyFile /etc/mongo/certs/server.pem \
  --tlsCAFile /etc/mongo/certs/ca.crt --tlsAllowInvalidCertificates \
  -u root -p example --authenticationDatabase admin \
  --eval 'db.adminCommand({ping:1})'
```

### Comprobar `beaconprod`

```bash
podman logs --tail=50 beaconprod
```

Debe escuchar en `5050`.

### Comprobar `idp`

```bash
podman logs --tail=50 idp
```

Debe llegar a:

```text
Running the server in development mode
Listening on: http://0.0.0.0:8082
```

### Comprobar la API por Apache

```bash
curl -s http://beaconaf-isciiiciber.isciiides.es:8443/api/info | jq .
```

Debe devolver el JSON de info del beacon con `beacon_id = 'es.isciii-ciber.beacon'`.

## Ingesta de un dataset

El flujo completo es:

1. preparar el VCF lifted a GRCh38 (output de [`impact-tools beacon pgx`](https://github.com/BU-ISCIII/impact-tools/tree/develop))
2. cargar variantes con `scripts/load_dataset_ritools.sh`
3. registrar metadatos del dataset con `scripts/register_dataset_metadata.sh`

### Cargar variantes

Desde `dcontainers00` (ejemplo para dataset `ISCIII_ES_WGSTRIO_3`):

```bash
cd /opt/beacon/beacon2-pi-api-isciii/scripts
./load_dataset_ritools.sh ISCIII_ES_WGSTRIO_3 \
  /impact_data/lega_data/beacon/inputs/ISCIII_ES_WGSTRIO_3.vcf.gz
```

El script:

1. valida que el VCF existe
2. actualiza `ri-tools/conf/conf.py` con el `datasetId`
3. limpia `ri-tools/files/vcf/files_to_read/` y copia el VCF
4. ejecuta ri-tools dentro del contenedor
5. verifica el número de variantes insertadas en MongoDB
6. guarda log y métricas en `/var/log/local/apps/beacon/ri-tools/`

### Registrar metadatos del dataset

```bash
./register_dataset_metadata.sh ISCIII_ES_WGSTRIO_3 \
  "ISCIII Spanish WGS Trio 3 (PGx aggregated)"
```

El script:

1. crea o actualiza `ri-tools/csv/datasets.csv`
2. pregunta interactivamente el nivel de acceso (`public`, `registered`, `controlled`)
3. pregunta si el dataset es sintético y si es de test
4. convierte CSV a BFF JSON con `csv_to_bff.py`
5. importa el JSON en MongoDB con `mongoimport`
6. actualiza `datasets_permissions.yml` y `datasets_conf.yml`
7. ejecuta `reindex`
8. ejecuta `extract_filtering_terms`
9. reinicia `beaconprod` y espera 15 s
10. verifica que el dataset aparece en la API

### Validar la carga en MongoDB

```bash
podman exec mongoprod mongosh \
  --tls --tlsCertificateKeyFile /etc/mongo/certs/server.pem \
  --tlsCAFile /etc/mongo/certs/ca.crt --tlsAllowInvalidCertificates \
  -u root -p example --authenticationDatabase admin \
  beacon --eval "db.genomicVariations.countDocuments({datasetId: 'ISCIII_ES_WGSTRIO_3'})"
```

### Validar el dataset en la API

```bash
curl -s "http://beaconaf-isciiiciber.isciiides.es:8443/api/datasets?requestedGranularity=record&limit=1000" \
  | jq -r '.response.collections[] | select(.id == "ISCIII_ES_WGSTRIO_3") | [.id, .name] | @tsv'
```

Debe devolver:

```text
ISCIII_ES_WGSTRIO_3    ISCIII Spanish WGS Trio 3 (PGx aggregated)
```

## Troubleshooting

### `setresuid ... Invalid argument` en cualquier contenedor

Causa:

- rango `subuid`/`subgid` insuficiente en Podman rootless

Solución:

- ampliar `/etc/subuid` y `/etc/subgid`
- verificar con `podman unshare cat /proc/self/uid_map`

### MongoDB no arranca con `wrong ownership`

Causa:

- `data/db` quedó con UID/GID incompatible

Solución:

```bash
podman unshare chown -R 999:999 beacon/connections/mongo/data
podman rm -f mongoprod
podman compose up -d mongoprod
```

### `beaconprod` no conecta a MongoDB

Causa:

- los certificados TLS no son legibles dentro del contenedor

Solución:

```bash
chmod 644 certs/ca.crt
chmod 600 certs/client.pem
podman restart beaconprod
```

### `ri-tools` falla con `Authentication failed`

Causa:

- credenciales o `database_auth_source` mal configurados en `ri-tools/conf/conf.py`

Verifica que `database_auth_source = 'admin'` y que el usuario y contraseña coinciden con los de `mongoprod`.

### `register_dataset_metadata.sh` aborta en `mongoimport`

Causa:

- el URI de conexión no tiene los flags TLS correctos

Verifica que el script tiene:

```text
mongodb://root:example@127.0.0.1:27017/beacon?authSource=admin&tls=true&tlsCAFile=...&tlsCertificateKeyFile=...
```

### La API devuelve `404` para el dataset recién cargado

Causa:

- no se ejecutó `reindex` o `extract_filtering_terms`
- `beaconprod` no se reinició después de actualizar `datasets_conf.yml`

Solución: ejecutar `register_dataset_metadata.sh` de nuevo, que hace todos los pasos en orden.

### Variantes en MongoDB pero el dataset no aparece en la API

Causa:

- el dataset existe en `db.genomicVariations` pero no en `db.datasets`

Verifica:

```bash
podman exec mongoprod mongosh \
  --tls --tlsCertificateKeyFile /etc/mongo/certs/server.pem \
  --tlsCAFile /etc/mongo/certs/ca.crt --tlsAllowInvalidCertificates \
  -u root -p example --authenticationDatabase admin \
  beacon --eval "db.datasets.countDocuments({id: 'ISCIII_ES_WGSTRIO_3'})"
```

Si devuelve `0`, ejecuta `register_dataset_metadata.sh` para registrar los metadatos.

### Keycloak no importa el realm

Causa:

- `beacon-realm.json` no está montado en el path correcto
- versión incompatible (este despliegue usa Keycloak 18)

Verifica:

```bash
podman exec idp ls /opt/keycloak/data/import/
```

Debe aparecer `beacon-realm.json`.

### Apache devuelve `502 Bad Gateway`

Causa:

- `beaconprod` no está corriendo o no escucha en `5050`

Verifica:

```bash
podman ps | grep beaconprod
podman logs --tail=20 beaconprod
```