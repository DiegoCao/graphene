#!/bin/bash

set -x

source ./environment.sh

echo "### phase.1 distribute the keys and password"
echo ">>> $MASTER"
ssh root@$MASTER "rm -rf $KEYS_PATH && rm -rf $SECURE_PASSWORD_PATH && mkdir -p $AZ_PPML_PATH"
scp -r $SOURCE_KEYS_PATH root@$MASTER:$KEYS_PATH
scp -r $SOURCE_SECURE_PASSWORD_PATH root@$MASTER:$SECURE_PASSWORD_PATH
for worker in ${WORKERS[@]}
  do
    echo ">>> $worker"
    ssh root@$worker "rm -rf $KEYS_PATH && rm -rf $SECURE_PASSWORD_PATH && mkdir -p $AZ_PPML_PATH"
    scp -r $SOURCE_KEYS_PATH root@$worker:$KEYS_PATH
    scp -r $SOURCE_SECURE_PASSWORD_PATH root@$worker:$SECURE_PASSWORD_PATH
  done
echo "### phase.1 distribute the keys and password finished successfully"

echo "### phase.2 pull the docker image"
echo ">>> $MASTER"
ssh root@$MASTER "docker pull $TRUSTED_CLUSTER_SERVING_DOCKER"
for worker in ${WORKERS[@]}
  do
    echo ">>> $worker"
    ssh root@$worker "docker pull $TRUSTED_CLUSTER_SERVING_DOCKER"
  done
echo "### phase.2 pull the docker image finished successfully"


echo "### phase.3 deploy the cluster serving components"
echo ">>> $MASTER, start redis"
ssh root@$MASTER "docker run -itd \
      --privileged \
      --net=host \
      --cpuset-cpus="0-2" \
      --oom-kill-disable \
      --name=redis \
      $TRUSTED_CLUSTER_SERVING_DOCKER bash -c 'cd /opt && ./start-redis.sh'"
while ! ssh root@$MASTER "nc -z $MASTER 6379"; do
  sleep 10
done
echo ">>> $MASTER, redis started successfully."

echo ">>> $MASTER, start flink-jobmanager"
ssh root@$MASTER "docker run -itd \
      --privileged \
      --net=host \
      --cpuset-cpus="3-5" \
      --oom-kill-disable \
      -v $KEYS_PATH:/opt/keys \
      -v $SECURE_PASSWORD_PATH:/opt/password \
      --name=flink-job-manager \
      -e FLINK_JOB_MANAGER_IP=$MASTER \
      -e FLINK_JOB_MANAGER_REST_PORT=8081 \
      -e FLINK_JOB_MANAGER_RPC_PORT=6123 \
      -e CORE_NUM=3 \
      $TRUSTED_CLUSTER_SERVING_DOCKER bash -c 'cd /opt && ./start-flink-jobmanager.sh'"
while ! ssh root@$MASTER "nc -z $MASTER 8081"; do
  sleep 10
done
echo ">>> $MASTER, flink-jobmanager started successfully."

for worker in ${WORKERS[@]}
  do
    echo ">>> $worker"
    ssh root@$worker "docker run -itd \
        --privileged \
        --net=host \
        --cpuset-cpus="6-30" \
        --oom-kill-disable \
        --device=/dev/sgx \
        -v $KEYS_PATH:/opt/keys \
        -v $SECURE_PASSWORD_PATH:/opt/password \
        --name=flink-task-manager-$worker \
        -e SGX_MEM_SIZE=64G \
        -e FLINK_JOB_MANAGER_IP=$MASTER \
        -e FLINK_JOB_MANAGER_REST_PORT=8081 \
        -e FLINK_JOB_MANAGER_RPC_PORT=6123 \
        -e FLINK_TASK_MANAGER_IP=$worker \
        -e FLINK_TASK_MANAGER_DATA_PORT=6124 \
        -e FLINK_TASK_MANAGER_RPC_PORT=6125 \
        -e FLINK_TASK_MANAGER_TASKSLOTS_NUM=1 \
        -e CORE_NUM=25 \
        $TRUSTED_CLUSTER_SERVING_DOCKER bash -c 'cd /opt && ./init-occlum-taskmanager.sh && ./start-flink-taskmanager.sh'"
  done

for worker in ${WORKERS[@]}
  do
    while ! ssh root@$worker "nc -z $worker 6124"; do
      sleep 10
    done
    echo ">>> $worker, flink-taskmanager-$worker started successfully."
  done

echo ">>> $MASTER, start http-frontend"
ssh root@$MASTER "docker run -itd \
      --privileged \
      --net=host \
      --cpuset-cpus="31-32" \
      --oom-kill-disable \
      --device=/dev/sgx \
      -v $KEYS_PATH:/opt/keys \
      -v $SECURE_PASSWORD_PATH:/opt/password \
      --name=http-frontend \
      -e SGX_MEM_SIZE=32G \
      -e REDIS_HOST=$MASTER \
      -e CORE_NUM=2 \
      $TRUSTED_CLUSTER_SERVING_DOCKER bash -c 'cd /opt && ./start-http-frontend.sh'"
while ! ssh root@$MASTER "nc -z $MASTER 10023"; do
  sleep 10
done
echo ">>> $MASTER, http-frontend started successfully."

echo ">>> $MASTER, start cluster-serving"
ssh root@$MASTER "docker run -itd \
      --privileged \
      --net=host \
      --cpuset-cpus="33-34" \
      --oom-kill-disable \
      -v $KEYS_PATH:/opt/keys \
      -v $SECURE_PASSWORD_PATH:/opt/password \
      --name=cluster-serving \
      -e REDIS_HOST=$MASTER \
      -e CORE_NUM=2 \
      -e FLINK_JOB_MANAGER_IP=$MASTER \
      -e FLINK_JOB_MANAGER_REST_PORT=8081 \
      $TRUSTED_CLUSTER_SERVING_DOCKER bash -c 'cd /opt && ./start-cluster-serving-job.sh'"
while ! ssh root@$MASTER "docker logs cluster-serving | grep 'Job has been submitted'"; do
  sleep 10
done
echo ">>> $MASTER, cluster-serving started successfully."
