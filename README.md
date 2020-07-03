# onedocker

**ONE Docker** project - an attempt to dockerize OpenNebula

**DISCLAIMER**:

    This is *Work-In-Progress* and *Proof-of-Concept* kind of thing - so it does not thrive to follow best-practices or guidelines how to create proper docker/microservice focused application.

**NOTE**:

    Due to simplicity reasons - all of OpenNebula's services are running inside the one big container `opennebula-frontend` (resembling more of a system container or VM - as of now).

## Usage

**IMPORTANT**:

    You must have installed [`podman`](https://podman.io) and [`podman-compose`](https://github.com/containers/podman-compose)!

### Build and start ONE Docker

```
$ git clone https://github.com/ospalax/onedocker.git
$ cd onedocker
$ podman-compose up --build -d
```

By default the OpenNebula's frontend (*Sunstone* web UI) will be accessible at `http://localhost:9000`. You can login there with `oneadmin/changeme123` credentials.

Inside this repo is the file `.env` where are defined default values used by `docker-compose/podman-compose` to start this application/service deployment.

You are encouraged to change these values.

### Stop ONE Docker

```
$ cd onedocker
$ podman-compose down
```

## Description

This project is trying to create full-featured OpenNebula installation/deployment implemented via application containers. The advantages are clear:

* simple and reproducible deployment
* easy switch to different OpenNebula version
* support for multiple instances running simultaneously
* overall ease-of-use for prototyping and testing of different OpenNebula versions

ONE Docker is reusing the OpenNebula's service files which are systemd's units - for that reason the `systemd` is needed to be running inside the container. The problem is that systemd inside a [`docker`](https://www.docker.com/) container fails to start - for the time being the *systemd* version is supported only by `podman` family of tools.

**NOTE**:

    There is a plan to create an alternative - more **docker** friendly - version which will not be relying on systemd but it will utilize some other init system more suited for container environment (`runit`?).

