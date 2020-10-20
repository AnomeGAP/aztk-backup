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

    echo "start install docker-ce"
    curl https://get.docker.com | sh
    sudo systemctl start docker && sudo systemctl enable docker
    echo "finish install docker-ce"

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
        echo "start install cuda10.0-"
        CUDA_DEB=cuda-repo-ubuntu1804_10.0.130-1_amd64.deb
        curl -O http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/$CUDA_DEB
        sudo apt-key adv --fetch-keys http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub
        sudo dpkg -i --force-overwrite ./$CUDA_DEB
        sudo apt-get -y update
        sudo apt-get -y install cuda-10-0
        echo "finish install cuda10.0-"

        echo "start install cudnn7.6.0.64"
        CUDNN_TAR_FILE="cudnn-10.0-linux-x64-v7.6.0.64.tgz"
        wget -q https://developer.download.nvidia.com/compute/redist/cudnn/v7.6.0/${CUDNN_TAR_FILE}
        tar -xzvf ${CUDNN_TAR_FILE}
        sudo cp -P cuda/include/cudnn.h /usr/local/cuda-10.0/include
        sudo cp -P cuda/lib64/libcudnn* /usr/local/cuda-10.0/lib64/
        sudo chmod a+r /usr/local/cuda-10.0/lib64/libcudnn*
        sudo ldconfig
        echo "finish install cudnn7.6.0.64"

        echo "start install nvidia-docker2"
        sudo apt-get update
        sudo apt-get install -y nvidia-docker2
        echo "finish install nvidia-docker2"


        echo "start restart docker"
        sudo systemctl restart docker
        echo "finish restart docker"
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
}

install_python_dependencies () {
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
    time(
        install_prerequisites
    ) 2>&1

    # set hostname in /etc/hosts if dns cannot resolve
    if ! host $HOSTNAME ; then
        echo $(hostname -I | awk '{print $1}') $HOSTNAME >> /etc/hosts
    fi

    time(
        install_docker_compose
    ) 2>&1

    time(
        pull_docker_container
    ) 2>&1

    # Unzip resource files and set permissions
    chmod 777 $AZTK_WORKING_DIR/aztk/node_scripts/docker_main.sh

    # Check docker is running
    docker info > /dev/null 2>&1
    if [ $? -ne 0 ]; then
    echo "UNKNOWN - Unable to talk to the docker daemon"
    exit 3
    fi

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

    time(
        install_python_dependencies
    ) 2>&1

    export PYTHONPATH=$PYTHONPATH:$AZTK_WORKING_DIR

    time(
        run_docker_container
    ) 2>&1

}

apt-mark hold $(uname -r)
main
apt-mark unhold $(uname -r)
