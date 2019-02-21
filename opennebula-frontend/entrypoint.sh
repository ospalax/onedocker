#!/bin/sh

set -e

ONEADMIN_USERNAME=oneadmin
MYSQL_HOST="${MYSQL_HOST:-db}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

################################################################################

#
# functions
#

setup_one_user()
{
    oneuser passwd 0 "$ONEADMIN_PASSWORD" || true
    echo "${ONEADMIN_USERNAME}:${ONEADMIN_PASSWORD}" > /var/lib/one/.one/one_auth
}

configure_oned()
{
    # db
    if grep -q \
        '^[[:space:]]*DB[[:space:]]*=.*BACKEND[[:space:]]*=[[:space:]]*["]\?sqlite' \
        /etc/one/oned.conf
    then
        sed -i 's/^[[:space:]]*DB[[:space:]]*=.*BACKEND[[:space:]]*=[[:space:]]*["]\?sqlite.*/#&/' \
            /etc/one/oned.conf

        cat >> /etc/one/oned.conf <<EOF

#*******************************************************************************
# Custom onedocker configuration
#*******************************************************************************
# This part was dynamically created by the onedocker container:
#   opennebula-frontend
#*******************************************************************************

DB = [ backend = "mysql",
       server  = "${MYSQL_HOST}",
       port    = ${MYSQL_PORT},
       user    = "${MYSQL_USER}",
       passwd  = "${MYSQL_PASSWORD}",
       db_name = "${MYSQL_DATABASE}" ]

EOF
    fi
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


################################################################################

#
# start service
#

echo ONEDOCKER START

# run prestart hook if any
if [ -f /prestart-hook.sh ] && [ -x /prestart-hook.sh ] ; then
    /prestart-hook.sh
fi

echo SETUP ONE USER PASSWORD
setup_one_user

echo SETUP ONE DB CONNECTION
configure_oned

echo WAIT FOR DATABASE
wait_for_mysql

echo CONFIGURE DATABASE
configure_db

exec "$@"
