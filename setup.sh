#!/bin/bash

STARTED_IN=$(TZ=$DEFAULT_TIMEZONE date)

ROOT_SSH_PASSPHRASE=

# Defaults
: ${SSH_KEYSCAN:='bitbucket.org,gitlab.com,github.com'}
: ${SPACES:='apps,backups'}
: ${DEFAULT_TIMEZONE:='Europe/Istanbul'}
: ${ROOT_PASSWORD:=$(openssl rand -hex 8)}
: ${DEFAULT_USER:='captain'}
: ${DEFAULT_USER_PASSWORD:=$(openssl rand -hex 8)}
: ${DEFAULT_WORKDIR:='/home/captain'}
: ${FORCE_INSTALL:=false}
: ${RUNNING_LOCAL:=false}

WEBHOOK_URL=

usage() {
    set +x
    cat 1>&2 <<HERE
Script for initial configurations of Docker, Docker Swarm and CapRover.
USAGE:
    curl -sSL https://github.com/caproverhub/CapInit/raw/main/setup.sh | bash -s -- [OPTIONS]

OPTIONS:
-h|--help                   Print help
-t|--timezone               Standard system timezone
--root-password             New root user password. The script forces the password update
--default-user              Alternative user (with super powers) that will be used for deploys and remote access later
--default-user-password
--workdir                   Folder where all files of this setup will be stored
--spaces                    Subfolders where applications will be allocated (eg. apps, backups)
--root-ssh-passphrase       Provides a passphrase for the ssh key
--ssh-passphrase            Provides a passphrase for the ssh key
--ip-address                Main node IP address
--local                     It determines whether it is a local installation or online, such as a VPS
-f|--force                  Force install/re-install

OPTIONS (Webhook):
--webhook-url               Ping URL with provisioning updates
HERE
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    -h | --help)
        usage
        exit 0
        ;;

    -f | --force)
        FORCE_INSTALL=true
        shift 1
        ;;

    --local)
        RUNNING_LOCAL=true
        shift 1
        ;;

    --root-ssh-passphrase)
        ROOT_SSH_PASSPHRASE="$2"
        shift 2
        ;;

    --ip-address)
        IP_ADRESS="$2"
        shift 2
        ;;

    -t | --timezone)
        DEFAULT_TIMEZONE="$2"
        shift 2
        ;;

    --root-password)
        ROOT_PASSWORD="$2"
        shift 2
        ;;

    --default-user)
        DEFAULT_USER="$2"
        shift 2
        ;;
    --default-user-password)
        DEFAULT_USER_PASSWORD="$2"
        shift 2
        ;;

    --ssh-passphrase)
        USER_SSH_PASSPHRASE="$2"
        shift 2
        ;;

    --workdir)
        DEFAULT_WORKDIR="$2"
        shift 2
        ;;

    --spaces)
        SPACES="$2"
        shift 2
        ;;

    --webhook-url)
        WEBHOOK_URL="$2"
        shift 2
        ;;

    *)                     # unknown option
        POSITIONAL+=("$1") # save it in an array for later
        echo "Parameter not known: $1"
        exit 1
        ;;
    esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

check_apache2() {
    if dpkg -l | grep -q apache2-bin; then
        error "You must uninstall the Apache2 server first."
    fi
}

# Ping URL With Provisioning Updates
function provision_ping {
    if [[ ! -z $WEBHOOK_URL ]]; then
        curl --max-time 15 --connect-timeout 60 --silent $WEBHOOK_URL \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            --data "{\"message\":\"$1\",\"status\":\"IN_PROGRESS\"}" >/dev/null 2>&1
    fi
}

# Outputs install log line
function setup_log() {
    provision_ping "$1"
    echo -e $1
}

function error() {
    provision_ping "$1"
    echo "$1" >&2
    exit 1
}

function install_report() {
    if [ ! -d /root/CapInit ]; then
        mkdir -p /root/CapInit
    fi

    echo $* >>/root/CapInit/install-report.txt
}

function create_docker_network() {
    NETWORK_NAME=$1
    setup_log "---> ⚡ Creating Docker network $NETWORK_NAME"
    docker network ls | grep $NETWORK_NAME >/dev/null || docker network create --driver=overlay $NETWORK_NAME
}

function ssh_keygen() {
    # $1 email $2 ssh_passphrase $3 path
    ssh-keygen -q -t rsa -b 4096 -f $3 -C "$1" -N "$2" >/dev/null 2>&1
}

# Remove images, volumes and containers from a previous unsuccessful attempt
function docker_reset() {
    setup_log "---> 🐳 Docker previously installed!"

    if $FORCE_INSTALL; then

        setup_log "---> 🔥 Resetting containers, images and networks."

        CONTAINERS=$(docker ps -a -q)
        if [[ ! -z $CONTAINERS ]]; then
            docker stop $CONTAINERS
            docker rm $CONTAINERS
            docker system prune -a --force
        fi

        VOLUMES=$(docker volume ls -q)
        if [[ ! -z $VOLUMES ]]; then
            docker volume rm $VOLUMES
        fi

    else
        setup_log "---> 🐳 Skipping Docker Installation."
    fi

}

function configure_firewall() {
    # 80 TCP for regular HTTP connections
    # 443 TCP for secure HTTPS connections
    # 7946 TCP/UDP for Container Network Discovery
    # 4789 TCP/UDP for Container Overlay Network
    # 2377 TCP/UDP for Docker swarm API
    # 996 TCP for secure HTTPS connections specific to Docker Registry

    setup_log "---> 🔄 Configuring Firewall"
    ufw allow 80,443,3000,996,7946,4789,2377/tcp
    ufw allow 7946,4789,2377/udp

}

function setup_caprover() {

    if [ "$RUNNING_LOCAL" ]; then
        IP_ADDRESS='127.0.0.1'
    else
        IP_ADDRESS=$(curl -s checkip.amazonaws.com)
    fi

    docker run \
        -p 80:80 \
        -p 443:443 \
        -p 3000:3000 \
        -e ACCEPTED_TERMS=true \
        -e MAIN_NODE_IP_ADDRESS=$IP_ADDRESS \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /captain:/captain \
        caprover/caprover
}

if [ "$(id -u)" != "0" ]; then
    error "❌ Sorry! This script must be run as root."
fi

if [ -f /root/CapInit/installed ]; then

    if $FORCE_INSTALL; then
        rm -rf /root/CapInit
    else
        error "❌ This server has already been configured. See /root/CapInit/install-report.txt for details."
    fi
fi

check_apache2

configure_firewall

# Update timezone
setup_log "---> 🔄 Updating packages and setting the timezone."
apt-get update -qq >/dev/null
timedatectl set-timezone $DEFAULT_TIMEZONE

setup_log "---> 🔄 Installing essential programs (git zip unzip curl wget acl apache2-utils nfs-common)."
apt-get install -y -qq --no-install-recommends git zip unzip curl wget acl apache2-utils nfs-common net-tools

if [ -x "$(command -v docker)" ]; then
    docker_reset
else
    setup_log "---> 🐳 Installing docker"
    curl -fsSL get.docker.com | sh
fi

# Set root password
setup_log "---> 🔑 Setting the root password"

if [[ -z $ROOT_PASSWORD ]]; then
    passwd
else
    echo $ROOT_PASSWORD | passwd >/dev/null 2>&1
    install_report "---> ROOT_PASSWORD: $ROOT_PASSWORD"
fi

# Creates SSH key from root if one does not exist
if [ ! -e /root/.ssh/id_rsa ]; then
    setup_log "---> 🔑 Creating the root user's SSH key"

    ssh_keygen "root" "$ROOT_SSH_PASSPHRASE" "/root/.ssh/id_rsa"
    install_report "---> ROOT_SSH_PASSPHRASE: $ROOT_SSH_PASSPHRASE"
else
    if $FORCE_INSTALL; then
        setup_log "---> 🔑 Recreating the root user's SSH key"
        rm /root/.ssh/*
        ssh_keygen "root" "$ROOT_SSH_PASSPHRASE" "/root/.ssh/id_rsa"
        install_report "---> ROOT_SSH_PASSPHRASE: $ROOT_SSH_PASSPHRASE"
    else
        setup_log "---> 🔑 Ignoring the existing root user's SSH key"
    fi
fi

# Create known_hosts file if it doesn't exist
if [ ! -e /root/.ssh/known_hosts ]; then
    setup_log "---> 📄 Creating file known_hosts"
    touch /root/.ssh/known_hosts
fi

# Create authorized_keys file if it doesn't exist
if [ ! -e /root/.ssh/authorized_keys ]; then
    setup_log "---> 📄 Creating file authorized_keys"
    touch /root/.ssh/authorized_keys
fi

# Adds bitbucket.org, gitlab.com, github.com
for S_KEYSCAN in $(echo $SSH_KEYSCAN | sed "s/,/ /g"); do
    setup_log "---> 🔄 Adding $S_KEYSCAN to trusted hosts"
    ssh-keyscan $S_KEYSCAN >>/root/.ssh/known_hosts
done

# Adds standard user, if one does not exist.
if [ $(sed -n "/^$DEFAULT_USER/p" /etc/passwd) ]; then
    setup_log "---> 👤 User $DEFAULT_USER already exists. Skipping..."
else
    setup_log "---> 👤 Creating standard user $DEFAULT_USER"
    useradd -s /bin/bash -d $DEFAULT_WORKDIR -m -U $DEFAULT_USER

    if [[ -z $DEFAULT_USER_PASSWORD ]]; then
        passwd $DEFAULT_USER
    else
        echo $DEFAULT_USER_PASSWORD | passwd $DEFAULT_USER >/dev/null 2>&1
    fi

    if [ ! -d $DEFAULT_WORKDIR/.ssh ]; then
        mkdir $DEFAULT_WORKDIR/.ssh
    fi

    cp /root/.ssh/known_hosts $DEFAULT_WORKDIR/.ssh/known_hosts
    cp /root/.ssh/authorized_keys $DEFAULT_WORKDIR/.ssh/authorized_keys

    setup_log "---> 🔑 Creating the $DEFAULT_USER user's SSH Keys"
    ssh_keygen "$DEFAULT_USER" "$USER_SSH_PASSPHRASE" "$DEFAULT_WORKDIR/.ssh/id_rsa"

    chown -R $DEFAULT_USER.$DEFAULT_USER $DEFAULT_WORKDIR/.ssh

    setup_log "---> 💪 Adding $DEFAULT_USER to sudoers with full privileges"
    echo "$DEFAULT_USER ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/$DEFAULT_USER
    chmod 0440 /etc/sudoers.d/$DEFAULT_USER

    setup_log "---> 🔄 Adding user $DEFAULT_USER to the docker group"
    usermod -aG docker $DEFAULT_USER

    setup_log "---> 🔄 Adding user $DEFAULT_USER to group www-data"
    usermod -aG www-data $DEFAULT_USER
fi

for SPACE in $(echo $SPACES | sed "s/,/ /g"); do
    if [ -d "$DEFAULT_WORKDIR/$SPACE" ]; then

        if $FORCE_INSTALL; then
            setup_log "---> 🔥 Deleting WORKDIR $SPACE from an previous attempt"
            rm -rf "$DEFAULT_WORKDIR/$SPACE/*"
        else
            setup_log "---> 📂 Skipping files from previous installation: $DEFAULT_WORKDIR/$SPACE"
        fi
    else
        setup_log "---> 📂 Creating working directory: $DEFAULT_WORKDIR/$SPACE"
        mkdir -p "$DEFAULT_WORKDIR/$SPACE"
    fi
done

setup_caprover

setup_log "---> 🧹 Cleaning up"
apt-get autoremove -y
apt-get clean -y

setup_log "---> 🔁 Changing owner of the root working directory to $DEFAULT_USER"
chown -R $DEFAULT_USER.$DEFAULT_USER $DEFAULT_WORKDIR

if [[ ! -z $WEBHOOK_URL ]]; then
    echo -e "🔄 Sending data to the Webhook."
    curl --max-time 15 --connect-timeout 60 --silent $WEBHOOK_URL \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data @<(
            cat <<EOF
    {
        "message": "Installation finished",
        "status": "FINISHED",
        "data": {
            "ROOT_SSH_PASSPHRASE": "$ROOT_SSH_PASSPHRASE",
            "USER_SSH_PASSPHRASE": "$USER_SSH_PASSPHRASE",
            "DEFAULT_TIMEZONE": "$DEFAULT_TIMEZONE",
            "ROOT_PASSWORD": "$ROOT_PASSWORD",
            "DEFAULT_USER": "$DEFAULT_USER",
            "DEFAULT_USER_PASSWORD": "$DEFAULT_USER_PASSWORD",

            "WORKDIR": "$DEFAULT_WORKDIR",
        }
    }
EOF
        ) >/dev/null 2>&1

fi

# Finish
echo -e "✅ Concluded!"

FINISHED_ON=$(TZ=$DEFAULT_TIMEZONE date)

install_report "Started in: $STARTED_IN"
install_report "Finished in: $FINISHED_ON"

echo $FINISHED_ON >/root/CapInit/installed

echo -e "📈 Install Report: /root/CapInit/install-report.txt"
cat /root/CapInit/install-report.txt

su $DEFAULT_USER
cd $DEFAULT_WORKDIR
