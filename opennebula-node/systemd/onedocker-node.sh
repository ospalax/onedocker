#!/bin/sh

set -e

ONEADMIN_USERNAME="${ONEADMIN_USERNAME:-oneadmin}"
OPENNEBULA_FRONTEND_HOSTNAME="${OPENNEBULA_FRONTEND_HOSTNAME:-opennebula-frontend}"
OPENNEBULA_NODE_SSHPORT="${OPENNEBULA_NODE_SSHPORT:-2222}"


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

configure_sshd_config()
{
    sed -i \
        -e '/PermitRootLogin/d' \
        -e '/PasswordAuthentication/d' \
        -e '/PermitEmptyPasswords/d' \
        -e '/PubkeyAuthentication/d' \
        -e '/Port/d' \
        /etc/ssh/sshd_config

    {
        echo 'PermitRootLogin no'
        echo 'PasswordAuthentication no'
        echo 'PermitEmptyPasswords no'
        echo 'PubkeyAuthentication yes'
        echo "Port ${OPENNEBULA_NODE_SSHPORT}"
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
        err "NO SSH KEY! You will have to join this node manually..."
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

enable_routing()
{
    _default_eth=$(ip route list default | sed -n 's/.*dev[ ]\+\([^ ]*\).*/\1/p')

    iptables -t nat -A POSTROUTING -o "$_default_eth" -j MASQUERADE

    sysctl -w net.ipv4.ip_forward=1
}

add_default_bridge()
{
    if [ -z "$OPENNEBULA_DEFAULT_VNET_BRIDGE" ] ; then
        msg "'OPENNEBULA_DEFAULT_VNET_BRIDGE' IS UNSET (no bridge will be setup)"
        return 0
    fi

    msg "CREATE BRIDGE: ${OPENNEBULA_DEFAULT_VNET_BRIDGE}"

    ip link add name "${OPENNEBULA_DEFAULT_VNET_BRIDGE}" type bridge
    ip link set "${OPENNEBULA_DEFAULT_VNET_BRIDGE}" up

    if [ -z "$OPENNEBULA_DEFAULT_VNET_ADDR" ] ; then
        msg "'OPENNEBULA_DEFAULT_VNET_ADDR' IS UNSET (no ip will be set to the bridge)"
        return 0
    fi

    msg "ASSIGN IP TO THE BRIDGE: ${OPENNEBULA_DEFAULT_VNET_ADDR}"
    ip addr add "${OPENNEBULA_DEFAULT_VNET_ADDR}" dev "${OPENNEBULA_DEFAULT_VNET_BRIDGE}"
}

#
# node services
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

prepare_node()
{
    msg "PREPARE ONEADMIN's SSH"
    prepare_ssh

    msg "CONFIGURE DATA"
    prepare_onedata

    msg "SETUP NETWORK"
    enable_routing
    add_default_bridge

    msg "START LIBVIRTD SERVICE"
    systemctl unmask libvirtd.service
    systemctl start libvirtd.service
}

###############################################################################
# start service
#

# run prestart hook if any
if [ -f /prestart-hook.sh ] && [ -x /prestart-hook.sh ] ; then
    /prestart-hook.sh
fi

msg "START (${0}): node"

# create one node
ssh
prepare_node

msg "DONE"

exit 0
