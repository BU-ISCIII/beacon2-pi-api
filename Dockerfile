##########################
## Build env
##########################

FROM python:3.10-bullseye AS BUILD

ENV DEBIAN_FRONTEND noninteractive

# Install dependences
RUN apt-get update 
#RUN apt-get upgrade -y
RUN apt-get install -y --no-install-recommends \
    ca-certificates pkg-config make gcc \
    libssl-dev libffi-dev libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# python packages
RUN pip install --upgrade pip
COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt


##########################
## Final image
##########################
FROM python:3.10-bullseye

LABEL maintainer="BU-ISCIII - Bioinformatics Unit ISCIII"
LABEL maintainer.email="bioinformatica@isciii.es"
LABEL org.label-schema.schema-version="2.0"
LABEL org.label-schema.name="Beacon v2 API - ISCIII"
LABEL org.label-schema.vcs-url="https://github.com/EGA-archive/beacon-2.x/"
LABEL org.bu-isciii.fork-url="https://github.com/BU-ISCIII/beacon2-pi-api"
LABEL org.label-schema.vendor="Instituto de Salud Carlos III"

COPY --from=BUILD /usr/local/bin      /usr/local/bin
COPY --from=BUILD /usr/local/lib      /usr/local/lib

RUN apt-get update && \
    apt update && apt install -y openssh-client sshpass && \
    apt-get install -y --no-install-recommends \
    nginx \
    && \
    rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list && \
    apt-get purge -y --auto-remove

# Usuario no-root (>1024) → OpenShift compliant
RUN useradd -u 10001 -m beacon
WORKDIR .

# Copia el código de beacon
COPY beacon/ /beacon/

# Permisos para Podman rootless
RUN chgrp -R 0 /beacon && chmod -R g=u /beacon
USER beacon
EXPOSE 5050
CMD ["python", "-m", "beacon"]
