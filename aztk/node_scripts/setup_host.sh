#!/bin/bash

# Entry point for the start task. It will install all dependencies and start docker.
# Usage:
# setup_host.sh [container_name] [docker_repo_name] [docker_run_options]
set -e

export AZTK_WORKING_DIR=/mnt/batch/tasks/startup/wd
export PYTHONUNBUFFERED=TRUE

container_name=$1
docker_repo_name=$2
docker_run_options=$3

install_prerequisites () {
    echo "Installing pre-reqs"
    SIXTY=60
    curl https://get.docker.com | sh
    sudo systemctl start docker && sudo systemctl enable docker


    echo "Setup the stable repository and the GPG key"
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    echo "the install url=https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list"
    curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list


    packages=(
        apt-transport-https
        curl
        ca-certificates
        software-properties-common
        python3-pip
        python3-venv
    )
    echo "running apt-get install -y --no-install-recommends \"${packages[@]}\""
    apt-get -y update &&
    apt-get install -y --no-install-recommends "${packages[@]}"


    if [ $AZTK_GPU_ENABLED == "true" ]; then
        START=$(date +%s)
        echo "start install nvidia-driver"
        sudo add-apt-repository ppa:graphics-drivers/ppa
        sudo apt-get update
        sudo apt install -y xserver-xorg-video-nvidia-418-server
        sudo apt install -y libnvidia-cfg1-418-server
        sudo apt install -y nvidia-driver-418-server
        echo "finish install nvidia-driver"

        echo "start install nvidia-docker2"
        sudo apt-get update
        sudo apt-get install -y nvidia-docker2
        echo "finish install nvidia-docker2"


        echo "start restart docker "
        sudo systemctl restart docker
        echo "finish restart docker "
        END=$(date +%s)
        DIFF=$(( $END - $START ))
        sec=$(($DIFF % $SIXTY))
        min=$(( $(( $DIFF - $sec )) / $SIXTY ))
        echo "GPU installation total: $min min $sec sec"
    fi
    echo "Finished installing pre-reqs"
}

install_docker_compose () {
    echo "Installing Docker-Compose"
    url=https://github.com/docker/compose/releases/download/1.19.0/docker-compose-`uname -s`-`uname -m`
    for i in {1..5}; do
        sudo curl -L $url -o /usr/local/bin/docker-compose && break ||
        echo "ERROR: failed to download docker-compose ... retrying in $($i**2) seconds" &&
        sleep $i**2;
    done
    sudo chmod +x /usr/local/bin/docker-compose
    echo "Finished installing Docker-Compose"
}

pull_docker_container () {
    echo "Pulling $docker_repo_name"

    if [ -z "$DOCKER_USERNAME" ]; then
        echo "No Credentials provided. No need to login to dockerhub"
    else
        echo "Docker credentials provided. Login in."
        docker login $DOCKER_ENDPOINT --username $DOCKER_USERNAME --password $DOCKER_PASSWORD
    fi

    for i in {1..5}; do
        docker pull $docker_repo_name && break ||
        echo "ERROR: docker pull $docker_repo_name failed ... retrying after $($i**2) seconds" &&
        sleep $i**2;
    done
    echo "Finished pulling $docker_repo_name"

    # Unzip resource files and set permissions
    chmod 777 $AZTK_WORKING_DIR/aztk/node_scripts/docker_main.sh

    # Check docker is running
    docker info > /dev/null 2>&1
    if [ $? -ne 0 ]; then
    echo "UNKNOWN - Unable to talk to the docker daemon"
    exit 3
    fi
}

install_python () {
    echo "Node python version:"
    python3 --version
    # set up aztk python environment
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    # pin pipenv dependencies (and transitive dependencies) since pipenv does not
    python3 -m pip install setuptools=="42.0.2"
    python3 -m pip install zipp=="1.1.0"
    python3 -m pip install virtualenv=="20.0.0"
    # ensure these packages (pip, pipenv) are compatibile before upgrading
    python3 -m pip install pip=="18.0" pipenv=="2018.7.1"
    python3 -m pip install --ignore-installed PyYAML=="5.3"
    python3 -m pip install importlib-resources=="1.0.2"
    mkdir -p $AZTK_WORKING_DIR/.aztk-env
    cp $AZTK_WORKING_DIR/aztk/node_scripts/Pipfile $AZTK_WORKING_DIR/.aztk-env
    cp $AZTK_WORKING_DIR/aztk/node_scripts/Pipfile.lock $AZTK_WORKING_DIR/.aztk-env
    cd $AZTK_WORKING_DIR/.aztk-env
    export PIPENV_VENV_IN_PROJECT=true
    #Installing python dependencies
    echo "Installing python dependencies"
    pipenv install --python /usr/bin/python3m --ignore-pipfile
    pip --version
    echo "Finished installing python dependencies"
}

run_docker_container () {
    echo "Running docker container"

    # If the container already exists just restart. Otherwise create it
    if [ "$(docker ps -a -q -f name=$container_name)" ]; then
        echo "Docker container is already setup. Restarting it."
        docker restart $container_name
    else
        echo "Creating docker container."

        echo "Running setup python script"
        $AZTK_WORKING_DIR/.aztk-env/.venv/bin/python $(dirname $0)/main.py setup-node $docker_repo_name "$docker_run_options"

        # wait until container is running
        until [ "`/usr/bin/docker inspect -f {{.State.Running}} $container_name`"=="true" ]; do
            sleep 0.1;
        done;

        # wait until container setup is complete
        echo "Waiting for spark docker container to setup."
        docker exec spark /bin/bash -c '$AZTK_WORKING_DIR/.aztk-env/.venv/bin/python $AZTK_WORKING_DIR/aztk/node_scripts/wait_until_setup_complete.py'

        # Setup symbolic link for the docker logs
        docker_log=$(docker inspect --format='{{.LogPath}}' $container_name)
        mkdir -p $AZ_BATCH_TASK_WORKING_DIR/logs
        ln -s $docker_log $AZ_BATCH_TASK_WORKING_DIR/logs/docker.log
    fi
    echo "Finished running docker container"
}


main () {
    SIXTY=60
    START1=$(date +%s)
    install_prerequisites
    END1=$(date +%s)
    DIFF=$(( $END1 - $START1 ))
    sec=$(($DIFF % $SIXTY))
    min=$(( $(( $DIFF - $sec )) / $SIXTY ))
    echo "Install_perrequisites(include GPU) total: $min min $sec sec"
    # set hostname in /etc/hosts if dns cannot resolve
    if ! host $HOSTNAME ; then
        echo $(hostname -I | awk '{print $1}') $HOSTNAME >> /etc/hosts
    fi

    START=$(date +%s)
    install_docker_compose
    END=$(date +%s)
    DIFF=$(( $END - $START ))
    sec=$(($DIFF % $SIXTY))
    min=$(( $(( $DIFF - $sec )) / $SIXTY ))
    echo "install_docker_compose total: $min min $sec sec"

    START=$(date +%s)
    pull_docker_container
    END=$(date +%s)
    DIFF=$(( $END - $START ))
    sec=$(($DIFF % $SIXTY))
    min=$(( $(( $DIFF - $sec )) / $SIXTY ))
    echo "pull_docker_container total: $min min $sec sec"

    START=$(date +%s)
    install_python
    END=$(date +%s)
    DIFF=$(( $END - $START ))
    sec=$(($DIFF % $SIXTY))
    min=$(( $(( $DIFF - $sec )) / $SIXTY ))
    echo "install_python total: $min min $sec sec"

    export PYTHONPATH=$PYTHONPATH:$AZTK_WORKING_DIR

    START=$(date +%s)
    run_docker_container
    END=$(date +%s)
    DIFF=$(( $END - $START ))
    sec=$(($DIFF % $SIXTY))
    min=$(( $(( $DIFF - $sec )) / $SIXTY ))
    echo "run_docker_container total: $min min $sec sec"
}

apt-mark hold $(uname -r)
STARTm=$(date +%s)
main
ENDm=$(date +%s)
DIFF=$(( $ENDm - $STARTm ))
sec=$(($DIFF % $SIXTY))
min=$(( $(( $DIFF - $sec )) / $SIXTY ))
echo "AZTK all process execution total: $min min $sec sec"
apt-mark unhold $(uname -r)
