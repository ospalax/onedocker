# onedocker

## ONE Docker project - an attempt to dockerize OpenNebula

### DISCLAIMERS (read them or do not complain)

* This is *Work-In-Progress* and *Proof-of-Concept* kind of thing - so it does not strive to be the definitive answer how to tackle this problem. This PoC also does not try to follow best-practices, patterns or guidelines how to create proper **docker/microservice/container** focused deployment. **So do not draw much inspiration from this...** (It may resemble more of a system containers rather than microservice containers...) Also due to the limitations in both the [`docker`](https://www.docker.com/) and the [`podman`](https://podman.io) the current state is just a working set of workarounds.
* **For the time being *only* `podman` and `podman-compose` is supported** because of `systemd` which cannot run inside the docker (while OpenNebula uses systemd services). Also due to the limits in the podman (**podman-in-podman** functionality and problematic support of [`docker.sock`](https://github.com/containers/podman/issues/6015)) the `opennebula-frontend` container must be run under the root user if Docker Hub marketplace should work (otherwise it is fine).
* I tried to support more than one distro but `CentOS` is the recommended for now. The problem is that currently systemd is needed inside the images (until I port OpenNebula systemd services to some other init system) and unfortunately `Debian` flavoured images keep crashing my host system for some reason (podman/systemd version messing with my cgroup?).
* Both containers (`opennebula-frontend` and `opennebula-node`) are running as **privileged** - bear that in mind...
* There is already a rewrite of systemctl services to supervisord in OpenNebula project (for the official ONE Docker image) - I plan to base runit rewrite on them once they are published and proper support for docker thanks to it...

## Usage

**IMPORTANT 1**:

You must have installed [`podman`](https://podman.io) (some later version **2+** preferably) and [`podman-compose`](https://github.com/containers/podman-compose). The podman-compose is in early stages of development and not all [`docker-compose`](https://docs.docker.com/compose/compose-file/) features are supported - therefore I recommend to use the devel version which may support more attributes found in my `docker-compose.yml` rather than a version of podman-compose installed via distro packages:

    $ curl -o /usr/local/bin/podman-compose https://raw.githubusercontent.com/containers/podman-compose/devel/podman_compose.py
    $ chmod +x /usr/local/bin/podman-compose

**IMPORTANT 2**:

While not mandatory I recommend to install `docker` on the host anyway and it **IS** mandatory (as of now) if you wish to use OpenNebula's Docker Hub marketplace. Podman in podman is a buggy mess and has too many issues to make it work (as of now).

Check your versions:

    $ podman version
    Version:      2.0.6
    API Version:  1
    Go Version:   go1.14.6
    Built:        Tue Sep  1 21:26:51 2020
    OS/Arch:      linux/amd64
    $ podman-compose version
    using podman version: podman version 2.0.6
    podman-composer version  0.1.7dev
    podman --version
    podman version 2.0.6
    0

### Build and start ONE Docker

**NOTE**:

Without `sudo` the Docker Hub marketplace will not work (and possibly other things).

```
$ git clone https://github.com/ospalax/onedocker.git
$ cd onedocker
$ podman-compose up --build -d
```

or for Debian flavour (**not** recommended - it randomly crashes):

```
$ ONEDOCKER_OS=debian podman-compose up --build -d
```

If you wish to use Docker Hub marketplace then you must uncomment `docker.sock` volume in the `docker-compose.yml` for `opennebula-frontend` container (service) and run with `sudo`:

```
$ sudo podman-compose up --build -d
```

By default the OpenNebula's frontend (*Sunstone* web UI) will be accessible at `http://localhost:9869`. You can login there with `oneadmin/changeme123` credentials.

Inside this repo is the file `.env` where are defined default values used by `docker-compose/podman-compose` to start this application/service deployment.

You are encouraged to change these values.

### Stop ONE Docker

```
$ cd onedocker
$ sudo podman-compose down
```

## Description

This project is trying to create full-featured OpenNebula installation/deployment implemented via application containers. The advantages are clear:

* simple and reproducible deployment
* easy switch to different OpenNebula version
* support for multiple instances running simultaneously
* overall ease-of-use for prototyping and testing of different OpenNebula versions

ONE Docker is reusing the OpenNebula's service files which are systemd's units - for that reason the `systemd` is needed to be running inside the container. The problem is that systemd inside a docker container fails to start and it is supported only by `podman` family of tools.

**NOTE**:

There is a plan to create an alternative - more docker friendly - version which will not be relying on systemd but it will utilize some other init system more suited for container environment (`runit`?).
