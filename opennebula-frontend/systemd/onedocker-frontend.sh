#!/bin/sh

set -e

ONEDOCKER_FRONTEND_SERVICE="${ONEDOCKER_FRONTEND_SERVICE:-all}"
ONEADMIN_USERNAME="${ONEADMIN_USERNAME:-oneadmin}"
MYSQL_HOST="${MYSQL_HOST:-db}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
OPENNEBULA_HOSTNAME="${OPENNEBULA_HOSTNAME:-opennebula-frontend}"


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

prepare_ssh()
{
    # ensure the existence of ssh directory
    if ! [ -d /oneadmin/ssh ] ; then
        mkdir -p /oneadmin/ssh

        if [ -f /var/lib/one/.ssh/config ] ; then
            mv /var/lib/one/.ssh/config /oneadmin/ssh/config
        fi
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
        ssh-keygen -N '' -f /oneadmin/ssh/id_rsa

        cat /oneadmin/ssh/id_rsa.pub > /oneadmin/ssh/authorized_keys
        chmod 644 /oneadmin/ssh/authorized_keys
    fi

    rm -rf /var/lib/one/.ssh
    ln -s /oneadmin/ssh /var/lib/one/.ssh

    chown -R "${ONEADMIN_USERNAME}:" /oneadmin/ssh
    chmod 700 /oneadmin/ssh
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
    sed -i "s/^[[:space:]#]*HOSTNAME[[:space:]]*=.*/HOSTNAME = \"${OPENNEBULA_HOSTNAME}\"/" \
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

#
# frontend services
#

ssh()
{
    msg "CONFIGURE SSH SERVICE"
    configure_sshd_config

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

msg "START (${0}): ${ONEDOCKER_FRONTEND_SERVICE}"

case "${ONEDOCKER_FRONTEND_SERVICE}" in
    all)
        msg "CONFIGURE FRONTEND SERVICE: ALL"
        ssh
        oned
        sunstone
        ;;
    oned)
        msg "CONFIGURE FRONTEND SERVICE: ONED"
        ssh
        oned
        ;;
    sunstone)
        msg "CONFIGURE FRONTEND SERVICE: SUNSTONE"
        sunstone
        ;;
    *)
        err "Unknown frontend service: ${ONEDOCKER_FRONTEND_SERVICE}"
        exit 1
        ;;
esac

msg "DONE"

exit 0
