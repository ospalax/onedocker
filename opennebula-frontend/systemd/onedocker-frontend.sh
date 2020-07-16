#!/bin/sh

set -e

OPENNEBULA_FRONTEND_SERVICE="${OPENNEBULA_FRONTEND_SERVICE:-all}"
OPENNEBULA_NODE_SSHPORT="${OPENNEBULA_NODE_SSHPORT:-22}"
ONEADMIN_USERNAME="${ONEADMIN_USERNAME:-oneadmin}"
MYSQL_HOST="${MYSQL_HOST:-db}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
OPENNEBULA_FRONTEND_HOSTNAME="${OPENNEBULA_FRONTEND_HOSTNAME:-opennebula-frontend}"
OPENNEBULA_NODE_IM_MAD="${OPENNEBULA_NODE_IM_MAD:-kvm}"
OPENNEBULA_NODE_VM_MAD="${OPENNEBULA_NODE_VM_MAD:-kvm}"


###############################################################################
# functions
#

msg()
{
    echo "[ONEDOCKER]: $*"
}

err()
{
    echo "[ONEDOCKER] [!] ERROR: $*"
}

# IMPORTANT!
#
# This is mandatory - before opennebula service is started it needs to have the
# current password of the oneadmin user in ~oneadmin/.one/one_auth. If it is
# the first run then it will be generated.
#
# The issue manifests when the container is restarted - this whole directory
# will be lost. That happens due to the containers being stateless *BUT* if
# this is not the first run then the password is already stored in database and
# we will have possibly newly generated password which will not match the one
# in the database.
#
# For these reasons we need to have a volume:
prepare_oneadmin_data()
{
    # ensure the existence of our auth directory
    if ! [ -d /oneadmin/auth ] ; then
        mkdir -p /oneadmin/auth
    fi

    # setup the .one
    rm -rf /var/lib/one/.one
    ln -s /oneadmin/auth /var/lib/one/.one

    # store the password if not already there
    if ! [ -f /var/lib/one/.one/one_auth ] ; then
        echo "${ONEADMIN_USERNAME}:${ONEADMIN_PASSWORD}" \
            > /var/lib/one/.one/one_auth
    fi

    # and ensure the correct permissions
    chown "${ONEADMIN_USERNAME}:" /oneadmin
    chown -R "${ONEADMIN_USERNAME}:" /oneadmin/auth
    chmod 700 /oneadmin/auth
}

prepare_sunstone_oneadmin_data()
{
    # ensure the existence of our auth directory
    if ! [ -d /oneadmin/auth ] ; then
        err "We need a 'sunstone_auth' inside '/oneadmin/auth'"
        exit 1
    fi

    # setup the .one
    rm -rf /var/lib/one/.one
    ln -s /oneadmin/auth /var/lib/one/.one
}

configure_sshd_config()
{
    sed -i \
        -e '/PermitRootLogin/d' \
        -e '/PasswordAuthentication/d' \
        -e '/PermitEmptyPasswords/d' \
        -e '/PubkeyAuthentication/d' \
        /etc/ssh/sshd_config

    {
        echo 'PermitRootLogin no'
        echo 'PasswordAuthentication no'
        echo 'PermitEmptyPasswords no'
        echo 'PubkeyAuthentication yes'
    } >> /etc/ssh/sshd_config
}

restore_ssh_host_keys()
{
    # create new or restore saved ssh host keys
    if ! [ -d /data/ssh_host_keys ] ; then
        # we have no keys saved
        mkdir -p /data/ssh_host_keys

        # force recreating of new host keys
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -A

        # save the keys
        cp -a /etc/ssh/ssh_host_* /data/ssh_host_keys/
    else
        # restore the saved ssh host keys
        cp -af /data/ssh_host_keys/ssh_host_* /etc/ssh/
    fi
}

prepare_ssh()
{
    # ensure the existence of ssh directory
    if ! [ -d /oneadmin/ssh ] ; then
        mkdir -p /oneadmin/ssh
    fi

    # save the ssh config if present
    if ! [ -f /oneadmin/ssh/config ] && [ -f /var/lib/one/.ssh/config ] ; then
        mv /var/lib/one/.ssh/config /oneadmin/ssh/config
    fi

    # copy the custom ssh key-pair
    _custom_key=no
    if [ -n "$ONEADMIN_SSH_PRIVKEY" ] && [ -n "$ONEADMIN_SSH_PUBKEY" ] ; then
        if [ -f "$ONEADMIN_SSH_PRIVKEY" ] && [ -f "$ONEADMIN_SSH_PUBKEY" ] ; then
            _custom_key=yes
            _privkey=$(basename "$ONEADMIN_SSH_PRIVKEY")
            _pubkey=$(basename "$ONEADMIN_SSH_PUBKEY")

            cat "$ONEADMIN_SSH_PRIVKEY" > "/oneadmin/ssh/${_privkey}"
            chmod 600 "/oneadmin/ssh/${_privkey}"

            cat "$ONEADMIN_SSH_PUBKEY" > "/oneadmin/ssh/${_pubkey}"
            chmod 644 "/oneadmin/ssh/${_pubkey}"

            cat "/oneadmin/ssh/${_pubkey}" > /oneadmin/ssh/authorized_keys
            chmod 644 /oneadmin/ssh/authorized_keys
        fi
    fi

    # generate ssh key-pair if no custom one is provided
    if [ "$_custom_key" != 'yes' ] ; then
        if ! [ -f /oneadmin/ssh/id_rsa ] || ! [ -f /oneadmin/ssh/id_rsa.pub ] ; then
            rm -f /oneadmin/ssh/id_rsa /oneadmin/ssh/id_rsa.pub
            ssh-keygen -N '' -f /oneadmin/ssh/id_rsa
        fi

        cat /oneadmin/ssh/id_rsa.pub > /oneadmin/ssh/authorized_keys
        chmod 644 /oneadmin/ssh/authorized_keys
    fi

    # maybe we are (have to) running opennebula node on a non-standard port
    # NOTE: workaround for the node and the frontend running on localhost
    if [ -n "${OPENNEBULA_NODE_HOSTNAME}" ] && \
       [ "${OPENNEBULA_NODE_SSHPORT}" -ne 22 ] ;
    then
        # we will proxy ssh to this new port
        cat >> /oneadmin/ssh/config <<EOF

Host ${OPENNEBULA_NODE_HOSTNAME}
  StrictHostKeyChecking yes
  ServerAliveInterval 10
  # IMPORTANT: set the following 'Control*' options the same way as above
  ControlMaster no
  ControlPersist 70s
  ControlPath /run/one/ssh-socks/ctl-M-%C.sock
  Port ${OPENNEBULA_NODE_SSHPORT}

EOF
    fi

    # IMPORTANT:
    # This is an ugly hack to workaround OpenNebula's hardwired requirement for
    # SSH to run on a standard 22 port but which will conflict with the same
    # port for SSH on the host (where frontend container is running)...
    #
    # It serves the purpose for what is worth...but much more sensible way
    # would be to just change SSH port on the host and let frontend to publish
    # its SSH on standard port 22...!!!
    if [ -n "${OPENNEBULA_FRONTEND_HOSTNAME}" ] && \
       [ "${OPENNEBULA_FRONTEND_PUBLISHED_SSHPORT}" -ne 22 ] ;
    then
        use_ssh_proxy
    fi

    # move oneadmin's ssh config dir onto the volume
    rm -rf /var/lib/one/.ssh
    ln -s /oneadmin/ssh /var/lib/one/.ssh

    chown -R "${ONEADMIN_USERNAME}:" /oneadmin/ssh
    chmod 700 /oneadmin/ssh
}

# BEWARE: THIS IS INCREDIBLY NASTY HACK BUT I AM KIND OF PROUD OF IT :)
use_ssh_proxy()
{
    # /var/lib/one/remotes/scripts_common.sh
    # /usr/lib/one/sh/scripts_common.sh
    # /var/tmp/one/scripts_common.sh

    # inject these
    #_frontend_ip="\$(LANG=C ping -W 3 -c 1 ${OPENNEBULA_FRONTEND_HOSTNAME} | sed -n '1s/^PING ${OPENNEBULA_FRONTEND_HOSTNAME} (\([^)]*\)).*/\1/p')"
    _frontend_ip="\$(ruby -e 'require \"resolv\"; puts Resolv.getaddress(\"${OPENNEBULA_FRONTEND_HOSTNAME}\");')"
    _proxy_command="-o ProxyCommand=\\\\\"ssh -W localhost:${OPENNEBULA_FRONTEND_PUBLISHED_SSHPORT} -q ${_frontend_ip}\\\\\""

    sed -i \
        -e "s/^SSH_FWD=.*/&\nSSH_FWD=\"\${SSH_FWD} ${_proxy_command}\"/" \
        /var/lib/one/remotes/scripts_common.sh

    cat /var/lib/one/remotes/scripts_common.sh \
        > /usr/lib/one/sh/scripts_common.sh

    if [ -f /var/tmp/one/scripts_common.sh ] ; then
        cat /var/lib/one/remotes/scripts_common.sh \
            > /var/tmp/one/scripts_common.sh
    fi
}

prepare_onedata()
{
    # ensure the existence of the datastores directory
    if ! [ -d /data/datastores ] ; then
        mkdir -p /data/datastores
    fi

    # setup the datastores
    rm -rf /var/lib/one/datastores
    ln -s /data/datastores /var/lib/one/datastores

    # and ensure the correct permissions
    chown -R "${ONEADMIN_USERNAME}:" /data/datastores
    chmod 750 /data/datastores
}

# if password was changed - update it and restart oned
setup_one_user()
{

    _old_auth=$(cat /var/lib/one/.one/one_auth)

    # was it changed?
    if [ "$_old_auth" = "${ONEADMIN_USERNAME}:${ONEADMIN_PASSWORD}" ] ; then
        # no...do nothing
        return 0
    fi

    # otherwise wait for opennebula API and setup a new password
    while sleep 1 ; do
        if _output=$(oneuser passwd 0 "$ONEADMIN_PASSWORD" 2>/dev/null) ; then
            echo "$_output"
            break
        fi
    done

    # do not forget to update the change in one_auth
    echo "${ONEADMIN_USERNAME}:${ONEADMIN_PASSWORD}" \
        > /var/lib/one/.one/one_auth

#    # setup sunstone password
#    oneuser passwd 1 --sha256 "${ONEADMIN_PASSWORD}"
#    echo "serveradmin:${ONEADMIN_PASSWORD}" > /var/lib/one/.one/oneflow_auth
#    echo "serveradmin:${ONEADMIN_PASSWORD}" > /var/lib/one/.one/ec2_auth
#    echo "serveradmin:${ONEADMIN_PASSWORD}" > /var/lib/one/.one/onegate_auth
#    echo "serveradmin:${ONEADMIN_PASSWORD}" > /var/lib/one/.one/occi_auth
#    echo "serveradmin:${ONEADMIN_PASSWORD}" > /var/lib/one/.one/sunstone_auth

    # after the change you must restart oned
    systemctl restart opennebula.service
}

configure_oned()
{
    # setup hostname
    sed -i "s/^[[:space:]#]*HOSTNAME[[:space:]]*=.*/HOSTNAME = \"${OPENNEBULA_FRONTEND_HOSTNAME}\"/" \
        /etc/one/oned.conf

    # comment-out all DB directives from oned configuration
    #
    # NOTE:
    #   debian/ubuntu uses mawk (1.3.3 Nov 1996) which does not support char.
    #   classes or EREs...
    </etc/one/oned.conf >/etc/one/oned.conf~tmp awk '
    BEGIN {
        state="nil";
    }
    {
        if (state == "nil") {
            if ($0 ~ /^[ ]*DB[ ]*=[ ]*\[/) {
                state = "left-bracket";
                print "# " $0;
            } else if ($0 ~ /^[ ]*DB[ ]*=/) {
                state = "db";
                print "# " $0;
            } else
                print;
        } else if (state == "db") {
            if ($0 ~ /^[ ]*\[/) {
                state = "left-bracket";
                print "# " $0;
            } else
                print "# " $0;
        } else if (state == "left-bracket") {
            if ($0 ~ /[ ]*]/) {
                state = "nil";
                print "# " $0;
            } else
                print "# " $0;
        }
    }
    '
    cat /etc/one/oned.conf~tmp > /etc/one/oned.conf
    rm -f /etc/one/oned.conf~tmp

    # add new DB connections based on the passed env. variables
    cat >> /etc/one/oned.conf <<EOF

#*******************************************************************************
# Custom onedocker configuration
#*******************************************************************************
# This part was dynamically created by the ONE Docker container:
#   opennebula-frontend
#*******************************************************************************

DB = [ backend = "mysql",
       server  = "${MYSQL_HOST}",
       port    = ${MYSQL_PORT},
       user    = "${MYSQL_USER}",
       passwd  = "${MYSQL_PASSWORD}",
       db_name = "${MYSQL_DATABASE}" ]

EOF
}

wait_for_mysql()
{
    while ! mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -D "$MYSQL_DATABASE" \
        -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        -e 'exit'
    do
        printf .
        sleep 1s
    done
    echo
}

configure_db()
{
    mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" \
        -u root -p"$MYSQL_ROOT_PASSWORD" \
        -e 'SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED;'
}

unmask_opennebula_services()
{
    # firstly unmask everything again
    systemctl list-unit-files | \
        awk '{if (($1 ~ /^opennebula/) && ($2 == "masked")) print $1;}' | \
        while read -r _oneservice ; do \
            systemctl unmask "${_oneservice}" ; \
        done ;
}

fix_docker()
{
    # save the gid of the docker.sock
    _docker_gid=$(stat -c %g /var/run/docker.sock)

    if getent group | grep -q '^docker:' ; then
        # we reassign the docker's GID to that of the actual docker.sock
        groupmod -g "$_docker_gid" docker
    else
        # we create docker group
        groupadd -r -g "$_docker_gid" docker
    fi

    # and we add oneadmin to the docker group
    gpasswd -a oneadmin docker
}

join_node()
{
    if [ -n "$OPENNEBULA_NODE_HOSTNAME" ] ; then
        msg "ADD NODE '${OPENNEBULA_NODE_HOSTNAME}' TO THE OPENNEBULA"
        su - oneadmin -c \
            "onehost create -i ${OPENNEBULA_NODE_IM_MAD} -v ${OPENNEBULA_NODE_VM_MAD} ${OPENNEBULA_NODE_HOSTNAME}"
    fi
}

#
# frontend services
#

ssh()
{
    msg "CONFIGURE SSH SERVICE"
    configure_sshd_config

    msg "PREPARE SSH HOST KEYS"
    restore_ssh_host_keys

    msg "START SSH SERVICE"
    systemctl unmask sshd.service
    systemctl start sshd.service
}

oned()
{
    msg "FIX DOCKER"
    fix_docker

    msg "PRESEED ONEADMIN's ONE_AUTH"
    prepare_oneadmin_data

    msg "PREPARE ONEADMIN's SSH"
    prepare_ssh

    msg "CONFIGURE DATA"
    prepare_onedata

    msg "CONFIGURE ONED (oned.conf)"
    configure_oned

    msg "WAIT FOR DATABASE"
    wait_for_mysql

    msg "CONFIGURE DATABASE"
    configure_db

    msg "START OPENNEBULA ONED SERVICE"
    unmask_opennebula_services
    systemctl start opennebula.service

    msg "SETUP ONEADMIN's PASSWORD"
    setup_one_user

    msg "START OPENNEBULA ONEGATE/ONEFLOW"
    systemctl start opennebula-flow.service
    systemctl start opennebula-gate.service
}

sunstone()
{
    msg "PREPARE ONEADMIN AUTH DATA"
    prepare_sunstone_oneadmin_data

    msg "WAIT FOR ONED"
    while ! [ -f /oneadmin/auth/sunstone_auth ] ; do
        sleep 1
    done

    msg "START OPENNEBULA SUNSTONE"
    unmask_opennebula_services
    systemctl start opennebula-sunstone.service
}

###############################################################################
# start service
#

# run prestart hook if any
if [ -f /prestart-hook.sh ] && [ -x /prestart-hook.sh ] ; then
    /prestart-hook.sh
fi

msg "START (${0}): ${OPENNEBULA_FRONTEND_SERVICE}"

case "${OPENNEBULA_FRONTEND_SERVICE}" in
    none)
        msg "MAINTENANCE MODE - NO RUNNING SERVICES"
        ;;
    all)
        msg "CONFIGURE FRONTEND SERVICE: ALL"
        ssh
        oned
        sunstone
        join_node
        ;;
    oned)
        msg "CONFIGURE FRONTEND SERVICE: ONED"
        ssh
        oned
        join_node
        ;;
    sunstone)
        msg "CONFIGURE FRONTEND SERVICE: SUNSTONE"
        sunstone
        ;;
    *)
        err "Unknown frontend service: ${OPENNEBULA_FRONTEND_SERVICE}"
        exit 1
        ;;
esac

msg "DONE"

exit 0
