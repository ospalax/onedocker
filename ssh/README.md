# ONE Docker SSH

**NOTE**:
  This file (in the least) enforces git to add this directory to the repo so it can be used as a volume/bindmount in the `docker-compose.yml`.

You can store your custom SSH key-pair here which can then be referenced by `ONEADMIN_SSH_PRIVKEY` and `ONEADMIN_SSH_PUBKEY` variables.
