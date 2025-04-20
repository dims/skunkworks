# Deploying the DeepSeek-V3 Model (full version) in Amazon EKS Using vLLM and LWS

## Table of Contents
- [Who Is This Guide For?](#who-is-this-guide-for)
- [Prerequisites](#prerequisites)
- [Creating a suitable EKS Cluster](#creating-a-suitable-eks-cluster)
- [A container image with EFA](#a-container-image-with-efa)
- [Verify the cluster](#verify-the-cluster)
- [Run the deepseek-v3 workload](#run-the-deepseek-v3-workload)
- [Take it for a spin!](#take-it-for-a-spin)
- [Bonus](#bonus)

## Who Is This Guide For?
This guide assumes you:
- Have intermediate Kubernetes experience (kubectl, Helm)
- Are familiar with AWS CLI and EKS
- Understand basic GPU concepts

This guide provides a streamlined process to deploy the 671B parameter DeepSeek-V3 MoE model on Amazon EKS using [vLLM](https://docs.vllm.ai/en/latest/serving/distributed_serving.html
) and LeaderWorkerSet API ([LWS](https://github.com/kubernetes-sigs/lws)). We will be deploying on [Amazon EC2 G6e](https://aws.amazon.com/ec2/instance-types/g6e/) instances as they are a bit more accessible/available and we want to see how to load models across multiple nodes.

The main idea here is to peel the onion to see how exactly folks are deploying these large models with a practical demonstration to understand all the pieces and how they fit together.

Latest versions of the files will be here:
https://github.com/dims/skunkworks/tree/main/v3

## Prerequisites

Before starting, ensure you have the following tools installed:

1. **AWS CLI**: For managing AWS resources.
2. **eksctl/eksdemo**: To create and manage EKS clusters.
3. **kubectl**: The command-line tool for Kubernetes.
4. **helm**: Kubernetes’ package manager.
5. **jq**: For parsing JSON.
6. **Docker**: For building container images.
7. **Hugging Face Hub access**: You’ll need a token to download the model.

## Creating a suitable EKS Cluster

We will use an AWS account with sufficient quota for four g6e.48xlarge instances (192 vCPUs, 1536GB RAM, 8x L40S Tensor Core GPUs that come with 48 GB of memory per GPU).

You can use [eksdemo](https://github.com/awslabs/eksdemo?tab=readme-ov-file#install-eksdemo) for example:
```
eksdemo create cluster deepseek-v3-cluster-001 \
  --os AmazonLinux2023 \
  --instance g6e.48xlarge \
  --max 4 --nodes 4 \
  --volume-size 2048 \
  --enable-efa \
  --addons eks-pod-identity-agent \
  --no-taints \
  --timeout 120m
```
if you want to use [eksctl](https://github.com/eksctl-io/eksctl/) instead, run the same above command with `--dry-run` to get the equivalent command and configuration yaml.

Essentially, have enough GPU nodes, have a large volume size on each node as well as enable EFA. You can use any tool of your choice, but remember you will have to adjust say for taints in the deployment yaml as needed.

🔍 Why EFA? Elastic Fabric Adapter accelerates inter-node communication, critical for multi-GPU inference.

## A container image with EFA

Ideally you would just use a public image from the vllm folks:
```
docker.io/vllm/vllm-openai:latest
```

However, we want to use EFA as [Elastic Fabric Adapter (EFA)](https://docs.aws.amazon.com/eks/latest/userguide/node-efa.html) enhances inter-node communication for high-performance computing and machine learning applications within Amazon EKS clusters.

In the following Dockerfile, we start by grabbing a powerful CUDA base image, then go on a installation spree, pulling in EFA, NCCL, and AWS-OFI-NCCL, while instructing apt to hang onto its downloaded packages. Once everything’s compiled, we carefully graft these freshly built libraries onto the vLLM image above.

🛠 GPU Compatibility: The COMPUTE_CAPABILITY_VERSION=90 is specific to L40S GPUs. Adjust this for your hardware.

```
# syntax=docker/dockerfile:1

ARG CUDA_VERSION=12.4.1
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu20.04 AS efa-build

ARG COMPUTE_CAPABILITY_VERSION=90
ARG AWS_OFI_NCCL_VERSION=1.13.2-aws
ARG EFA_INSTALLER_VERSION=1.38.0
ARG NCCL_VERSION=2.24.3

RUN <<EOT
  rm -f /etc/apt/apt.conf.d/docker-clean
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
  echo 'APT::Install-Suggests "0";' >> /etc/apt/apt.conf.d/00-docker
  echo 'APT::Install-Recommends "0";' >> /etc/apt/apt.conf.d/00-docker

  echo 'tzdata tzdata/Areas select America' | debconf-set-selections
  echo 'tzdata tzdata/Zones/America select Chicago' | debconf-set-selections
EOT

RUN <<EOT
  apt update
  apt install -y \
    curl \
    git \
    libhwloc-dev \
    pciutils \
    python3

  # EFA installer
  cd /tmp
  curl -sL https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz | tar xvz
  cd aws-efa-installer

  ./efa_installer.sh --yes --skip-kmod --skip-limit-conf --no-verify --mpi openmpi5

  echo "/opt/amazon/openmpi5/lib" > /etc/ld.so.conf.d/openmpi.conf
  ldconfig

  # NCCL
  cd /tmp
  git clone https://github.com/NVIDIA/nccl.git -b v${NCCL_VERSION}-1
  cd nccl
  rm /opt/nccl/lib/*.a

  make -j $(nproc) src.build \
    BUILDDIR=/opt/nccl \
    CUDA_HOME=/usr/local/cuda \
    NVCC_GENCODE="-gencode=arch=compute_${COMPUTE_CAPABILITY_VERSION},code=sm_${COMPUTE_CAPABILITY_VERSION} -gencode=arch=compute_${COMPUTE_CAPABILITY_VERSION},code=sm_${COMPUTE_CAPABILITY_VERSION}"

  echo "/opt/nccl/lib" > /etc/ld.so.conf.d/000_nccl.conf
  ldconfig

  # AWS-OFI-NCCL plugin
  cd /tmp
  curl -sL https://github.com/aws/aws-ofi-nccl/releases/download/v${AWS_OFI_NCCL_VERSION}/aws-ofi-nccl-${AWS_OFI_NCCL_VERSION}.tar.gz | tar xvz
  cd aws-ofi-nccl-${AWS_OFI_NCCL_VERSION}

  ./configure --prefix=/opt/aws-ofi-nccl/install \
    --with-mpi=/opt/amazon/openmpi5 \
    --with-libfabric=/opt/amazon/efa \
    --with-cuda=/usr/local/cuda \
    --enable-tests=no \
    --enable-platform-aws
  make -j $(nproc)
  make install

  echo "/opt/aws-ofi-nccl/install/lib" > /etc/ld.so.conf.d/000-aws-ofi-nccl.conf
  ldconfig
EOT

################################################################

FROM docker.io/vllm/vllm-openai:latest

COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libhwloc.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libltdl.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libefa.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libhns.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libmana.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libmlx4.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libmlx5.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libibverbs.* /usr/lib/x86_64-linux-gnu/
COPY --from=efa-build /usr/lib/x86_64-linux-gnu/libibverbs /usr/lib/x86_64-linux-gnu/libibverbs
COPY --from=efa-build /opt/amazon /opt/amazon
COPY --from=efa-build /opt/aws-ofi-nccl /opt/aws-ofi-nccl
COPY --from=efa-build /opt/nccl/lib /opt/nccl/lib
COPY --from=efa-build /etc/ld.so.conf.d /etc/ld.so.conf.d

ENV LD_PRELOAD=/opt/nccl/lib/libnccl.so

COPY ./ray_init.sh /ray_init.sh
RUN <<EOT
  chmod +x /ray_init.sh
  pip install huggingface_hub[hf_transfer]
  pip install -U "ray[default]" "ray[cgraph]"
EOT
```

Note we also install `hugging_hub` with the high speed `hf_transfer` component and update the `ray` package. There is a `ray_init.sh` which helps us start `vllm` and `ray` in the leader and worker nodes brought up by LWS.

```
#!/bin/bash

subcommand=$1
shift

ray_port=6379
ray_init_timeout=300
declare -a start_params

case "$subcommand" in
  worker)
    ray_address=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --ray_address=*)
          ray_address="${1#*=}"
          ;;
        --ray_port=*)
          ray_port="${1#*=}"
          ;;
        --ray_init_timeout=*)
          ray_init_timeout="${1#*=}"
          ;;
        *)
          start_params+=("$1")
      esac
      shift
    done

    if [ -z "$ray_address" ]; then
      echo "Error: Missing argument --ray_address"
      exit 1
    fi

    until ray status --address $ray_address:$ray_port; do
      echo "Waiting until the ray status is active for leader..."
      sleep 5s;
    done

    for (( i=0; i < $ray_init_timeout; i+=5 )); do
      ray start --address=$ray_address:$ray_port --block "${start_params[@]}"
      if [ $? -eq 0 ]; then
        echo "Worker: Ray runtime started with head address $ray_address:$ray_port"
        exit 0
      fi
      echo "Waiting until the ray worker is active..."
      sleep 5s;
    done
    echo "Ray worker starts timeout, head address: $ray_address:$ray_port"
    exit 1
    ;;

  leader)
    ray_cluster_size=""
    while [ $# -gt 0 ]; do
          case "$1" in
            --ray_port=*)
              ray_port="${1#*=}"
              ;;
            --ray_cluster_size=*)
              ray_cluster_size="${1#*=}"
              ;;
            --ray_init_timeout=*)
              ray_init_timeout="${1#*=}"
              ;;
            *)
              start_params+=("$1")
          esac
          shift
    done

    if [ -z "$ray_cluster_size" ]; then
      echo "Error: Missing argument --ray_cluster_size"
      exit 1
    fi

    # start the ray daemon
    ray start --head --include-dashboard=true --port=$ray_port "${start_params[@]}"

    # wait until all workers are active
    for (( i=0; i < $ray_init_timeout; i+=5 )); do
        active_nodes=`python3 -c 'import ray; ray.init(); print(sum(node["Alive"] for node in ray.nodes()))'`
        if [ $active_nodes -eq $ray_cluster_size ]; then
          echo "All ray workers are active and the ray cluster is initialized successfully."
          exit 0
        fi
        echo "Wait for all ray workers to be active. $active_nodes/$ray_cluster_size is active"
        sleep 5s;
    done

    echo "Waiting for all ray workers to be active timed out."
    exit 1
    ;;

  *)
    echo "unknown subcommand: $subcommand"
    exit 1
    ;;
esac
```

Both these files are adaptations of code written by various folks and are available [here](https://github.com/vllm-project/vllm/blob/a018e555fd872ead45a1ab13d86626bb37064076/examples/online_serving/multi-node-serving.sh) and [here](https://github.com/aws-ia/terraform-aws-eks-blueprints/tree/main/patterns/multi-node-vllm).

## Verify the cluster

### Step 1: Check Daemonsets
- Check if the Nvidia and EFA daemonsets are running
```
kubectl get daemonsets -A | grep -E 'nvidia|efa'
```
```
kube-system   aws-efa-k8s-device-plugin        1         1         1       1            1           <none>          11m
kube-system   nvidia-device-plugin-daemonset   1         1         1       1            1           <none>          11m
```

### Step 2: Verify Node Resources
- Check if the nodes are correctly annotated with the GPU count and EFA capacity
```
kubectl get nodes -o json | jq -r '
  ["NODE", "NVIDIA_GPU", "EFA_CAPACITY"],
  (.items[] |
    [
      .metadata.name,
      (.status.capacity."nvidia.com/gpu" // "0"),
      (.status.capacity."vpc.amazonaws.com/efa" // "0")
    ]
  ) | @tsv' | column -t -s $'\t'
```
```
NODE                                            NVIDIA_GPU  EFA_CAPACITY
i-08982f78fb3e2b7d7.us-west-2.compute.internal  8           4
```
### Step 3: Inspect Hardware
- install the `node-shell` kubectl/krew plugin to peek into the nodes (will be handy for later)
```
kubectl krew install node-shell
```
- Now check if the devices are correctly present in each node
```
kubectl get nodes -o name | cut -d/ -f2 | \
  xargs -I{} sh -c 'echo "=== {} ==="; kubectl node-shell {} -- sh -c "lspci | grep -iE \"nvidia|amazon.*(efa)\"";'
```
```
=== i-08982f78fb3e2b7d7.us-west-2.compute.internal ===
spawning "nsenter-k9hss5" on "i-08982f78fb3e2b7d7.us-west-2.compute.internal"
9b:00.0 Ethernet controller: Amazon.com, Inc. Elastic Fabric Adapter (EFA)
9c:00.0 Ethernet controller: Amazon.com, Inc. Elastic Fabric Adapter (EFA)
9e:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
a0:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
a2:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
a4:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
bc:00.0 Ethernet controller: Amazon.com, Inc. Elastic Fabric Adapter (EFA)
bd:00.0 Ethernet controller: Amazon.com, Inc. Elastic Fabric Adapter (EFA)
c6:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
c8:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
ca:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
cc:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
pod "nsenter-k9hss5" deleted
```

## Run the deepseek-v3 workload

### Install LWS Controller
Use helm to install LWS:
```bash
helm install lws oci://registry.k8s.io/lws/charts/lws \
  --version=0.6.1 \
  --namespace lws-system \
  --create-namespace \
  --wait --timeout 300s
```

Check if the LWS pods are running:
```
kubectl get pods -n lws-system
```
```
NAME                                      READY   STATUS    RESTARTS   AGE
lws-controller-manager-696b448fb9-fxxs8   1/1     Running   0          88s
```

Edit `deepseek-lws.yaml` to insert your hugging face token (ensure it's base64 encoded):
```
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: vllm
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 4
    restartPolicy: RecreateGroupOnPodRestart
    leaderTemplate:
      metadata:
        labels:
          role: leader
      spec:
        containers:
          - name: vllm-leader
            image: ghcr.io/dims/skunkworks/vllm-v3:89-775754b81f110d1d5c3165ef277e5571b18e5da4
            securityContext:
              privileged: true
              capabilities:
                add: ["IPC_LOCK"]
            env:
              - name: NCCL_DEBUG
                value: "TRACE"
              - name: NCCL_DEBUG_SUBSYS
                value: "ALL"
              - name: NCCL_IB_DISABLE
                value: "1"
              - name: NCCL_P2P_DISABLE
                value: "1"
              - name: NCCL_NET_GDR_LEVEL
                value: "0"
              - name: NCCL_SHM_DISABLE
                value: "1"
              - name: PYTORCH_CUDA_ALLOC_CONF
                value: "max_split_size_mb:512,expandable_segments:True"
              - name: CUDA_MEMORY_FRACTION
                value: "0.95"
              - name: FI_EFA_USE_DEVICE_RDMA
                value: "1"
              - name: FI_PROVIDER
                value: "efa"
              - name: FI_EFA_FORK_SAFE
                value: "1"
              - name: HF_HUB_ENABLE_HF_TRANSFER
                value: "1"
              - name: HF_HOME
                value: "/local/huggingface"
              - name: HF_HUB_VERBOSITY
                value: "debug"
              - name: HF_TOKEN
                valueFrom:
                  secretKeyRef:
                    name: hf-token-secret
                    key: token
              - name: MODEL_REPO
                value: "deepseek-ai/DeepSeek-V3"
            command: ["/bin/bash"]
            args:
              - "-c"
              - |
                set -x

                # start ray leader
                /ray_init.sh leader --ray_cluster_size=$(LWS_GROUP_SIZE);
                sleep 30
                ray status

                # download and install model
                huggingface-cli download ${MODEL_REPO}

                # start vllm server
                vllm serve ${MODEL_REPO} \
                  --host 0.0.0.0 \
                  --port 8000 \
                  --tensor-parallel-size 8 \
                  --pipeline-parallel-size 4 \
                  --disable-log-requests \
                  --uvicorn-log-level error \
                  --max-model-len 32768 \
                  --trust-remote-code \
                  --device cuda \
                  --gpu-memory-utilization 0.8
            resources:
              limits:
                nvidia.com/gpu: "8"
                cpu: "96"
                memory: 384Gi
                vpc.amazonaws.com/efa: 4
              requests:
                nvidia.com/gpu: "8"
                cpu: "96"
                memory: 384Gi
                vpc.amazonaws.com/efa: 4
            ports:
              - containerPort: 8000
            readinessProbe:
              tcpSocket:
                port: 8000
              initialDelaySeconds: 15
              periodSeconds: 10
            volumeMounts:
              - name: local-storage
                mountPath: /local
              - name: shm
                mountPath: /dev/shm
        volumes:
        - name: local-storage
          hostPath:
            path: /root/local
            type: DirectoryOrCreate
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: "512Gi"
    workerTemplate:
      spec:
        containers:
          - name: vllm-worker
            image: ghcr.io/dims/skunkworks/vllm-v3:89-775754b81f110d1d5c3165ef277e5571b18e5da4
            securityContext:
              privileged: true
              capabilities:
                add: ["IPC_LOCK"]
            env:
              - name: HF_HUB_ENABLE_HF_TRANSFER
                value: "1"
              - name: HF_HOME
                value: "/local/huggingface"
              - name: HF_HUB_VERBOSITY
                value: "debug"
              - name: HF_TOKEN
                valueFrom:
                  secretKeyRef:
                    name: hf-token-secret
                    key: token
              - name: NCCL_DEBUG
                value: "TRACE"
            command: ["/bin/bash"]
            args:
              - "-c"
              - |
                set -x
                # start ray worker
                /ray_init.sh worker --ray_address=$(LWS_LEADER_ADDRESS)
            resources:
              limits:
                nvidia.com/gpu: "8"
                cpu: "96"
                memory: 384Gi
                vpc.amazonaws.com/efa: 4
              requests:
                nvidia.com/gpu: "8"
                cpu: "96"
                memory: 384Gi
                vpc.amazonaws.com/efa: 4
            volumeMounts:
              - name: local-storage
                mountPath: /local
              - name: shm
                mountPath: /dev/shm
        volumes:
        - name: local-storage
          hostPath:
            path: /root/local
            type: DirectoryOrCreate
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: "512Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-leader
spec:
  ports:
    - name: port-8000
      port: 8000
      targetPort: 8000
    - name: port-8265
      port: 8265
      targetPort: 8265
  type: ClusterIP
  selector:
    leaderworkerset.sigs.k8s.io/name: vllm
    role: leader
---
apiVersion: v1
kind: Secret
metadata:
  name: hf-token-secret
type: Opaque
data:
  token: "PASTE_BASE_64_VERSION_OF_YOUR_HF_TOKEN_HERE"

```

Important: Replace "PASTE_BASE_64_VERSION_OF_YOUR_HF_TOKEN_HERE" with the base64 encoded version of your Hugging Face token. To base64 encode it, you can use a tool like `echo -n 'your_token' | base64`

A Couple of other things to point out, if you see the `vllm` command line you will notice
```
    --tensor-parallel-size 8 \
    --pipeline-parallel-size 4 \
```
Across the 4 notes we have 32 GPUs, we are splitting these into 8 way tensor-parallel and 4 pipeline stages for a total of 32 (read about these params [here](https://docs.vllm.ai/en/latest/serving/distributed_serving.html#running-vllm-on-a-single-node)).

Apply the yaml using kubectl

```bash
kubectl apply -f deepseek-lws.yaml
```
```
leaderworkerset.leaderworkerset.x-k8s.io/vllm created
service/vllm-leader unchanged
secret/hf-token-secret unchanged
```

Check on the vllm pods:
```
kubectl get pods
```
```
NAME       READY   STATUS    RESTARTS   AGE
vllm-0     0/1     Running   0          50s
vllm-0-1   1/1     Running   0          50s
vllm-0-2   1/1     Running   0          50s
vllm-0-3   1/1     Running   0          50s
```

You will need to wait until `vllm-0` gets to `1/1`. You can check in on what is happening inside the main pod using
```
kubectl logs vllm-0 -f
```

In the `deepseek-lws.yaml`, you will notice that we have turned up all the logging way up high so you get an idea of all the things happening (or not!) in the system. Once you get familiar, you can turn down the settings to as much as you wish.

You will see the model being downloaded:
```
(RayWorkerWrapper pid=444, ip=192.168.130.178) Downloading 'model-00118-of-000163.safetensors' to '/local/huggingface/hub/models--deepseek-ai--DeepSeek-V3/blobs/72680742383e3ac1d20bc8abef7c730f880310b88a07e72d5a6ee47bc38613e9.incomplete'
(RayWorkerWrapper pid=444, ip=192.168.130.178) Downloading 'model-00119-of-000163.safetensors' to '/local/huggingface/hub/models--deepseek-ai--DeepSeek-V3/blobs/a7f04447b66d432a8800d6fb40788f980bd74d679716cb3ea6ed4ef328c73b43.incomplete'
(RayWorkerWrapper pid=444, ip=192.168.130.178) Downloading 'model-00120-of-000163.safetensors' to '/local/huggingface/hub/models--deepseek-ai--DeepSeek-V3/blobs/a540ce2f0766c50c12a7af78f41b3f5b6b64ebe8cdc804ee0ff8ff81a90248cc.incomplete'
```

If you inspect deepseek-lws.yaml, you will see that `/root/local` directory on the host is used to store the model. So even if the pods fail for some reason, the next pod will pick up downloading from where the previous pod failed.

After a while you will see the following:
```
Loading safetensors checkpoint shards:  94% Completed | 153/163 [00:13<00:00, 23.11it/s]
Loading safetensors checkpoint shards:  96% Completed | 156/163 [00:13<00:00, 22.98it/s]
Loading safetensors checkpoint shards:  98% Completed | 159/163 [00:13<00:00, 22.92it/s]
Loading safetensors checkpoint shards: 100% Completed | 163/163 [00:13<00:00, 12.10it/s]
```

Once you see the following, the vllm openapi endpoint is ready!
```
INFO 04-19 18:04:54 [launcher.py:26] Available routes are:
INFO 04-19 18:04:54 [launcher.py:34] Route: /openapi.json, Methods: HEAD, GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /docs, Methods: HEAD, GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /docs/oauth2-redirect, Methods: HEAD, GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /redoc, Methods: HEAD, GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /health, Methods: GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /load, Methods: GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /ping, Methods: POST, GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /tokenize, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /detokenize, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /v1/models, Methods: GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /version, Methods: GET
INFO 04-19 18:04:54 [launcher.py:34] Route: /v1/chat/completions, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /v1/completions, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /v1/embeddings, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /pooling, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /score, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /v1/score, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /v1/audio/transcriptions, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /rerank, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /v1/rerank, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /v2/rerank, Methods: POST
INFO 04-19 18:04:54 [launcher.py:34] Route: /invocations, Methods: POST
```

## Take it for a spin!

### Access the API
To access the DeepSeek-V3 model using your localhost, use the following command:
```bash
kubectl port-forward svc/vllm-leader 8000:8000 8265:8265
```

To check if the model is registered using the openapi spec, use the following command:
```bash
curl -X GET "http://127.0.0.1:8000/v1/models" | jq
```

To test the deployment use the following command:
```bash
curl -X POST "http://127.0.0.1:8000/v1/chat/completions" \
-H "Content-Type: application/json" \
-d '{
    "model": "deepseek-ai/DeepSeek-V3",
    "messages": [
        {
            "role": "user",
            "content": "What is Kubernetes?"
        }
    ]
}' | jq
```

you will see something like:
```
{
  "id": "chatcmpl-f0447f97931d49bab156dfd266055de0",
  "object": "chat.completion",
  "created": 1745112232,
  "model": "deepseek-ai/DeepSeek-V3",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "reasoning_content": null,
        "content": "Kubernetes, often abbreviated as K8s, is an open-source platform designed to automate deploying, scaling, and operating application containers. It was originally developed by Google and is now maintained by the Cloud Native Computing Foundation (CNCF).\n\nHere are some key features and components of Kubernetes:\n\n1. **Container Orchestration**: Kubernetes manages containerized applications across a cluster of machines. It ensures that the desired number of containers are running and can automatically replace any that fail.\n\n2. **Scaling**: Kubernetes can automatically scale applications up or down based on demand, ensuring optimal resource utilization.\n\n3. **Service Discovery and Load Balancing**: Kubernetes can expose a container using a DNS name or its own IP address. If traffic to a container is high, Kubernetes can load balance and distribute the network traffic to stabilize the deployment.\n\n4. **Storage Orchestration**: Kubernetes allows you to automatically mount a storage system of your choice, whether local storage, public cloud providers, or network storage systems.\n\n5. **Self-Healing**: Kubernetes can restart containers that fail, replace containers, kill containers that don't respond to your user-defined health check, and advertise them to clients only when they are ready to serve.\n\n6. **Automated Rollouts and Rollbacks**: Kubernetes allows you to describe the desired state for your deployed containers and can change the actual state to the desired state at a controlled rate. If something goes wrong, Kubernetes can roll back the change.\n\n7. **Configurations and Secrets**: Kubernetes manages configurations and secrets, ensuring sensitive information is securely handled and configurations are consistent across environments.\n\n8. **Portability**: Kubernetes can run on various platforms, including on-premises, public cloud, and hybrid environments, making it highly flexible.\n\nKubernetes uses a declarative model to define the desired state of the system, and it continuously works to maintain that state. It is widely used in the industry for managing containerized applications in production environments.",
        "tool_calls": []
      },
      "logprobs": null,
      "finish_reason": "stop",
      "stop_reason": null
    }
  ],
  "usage": {
    "prompt_tokens": 7,
    "total_tokens": 397,
    "completion_tokens": 390,
    "prompt_tokens_details": null
  },
  "prompt_logprobs": null
}
```

Now feel free to tweak the `deepseek-lws.yaml` and re-apply the changes using:
```
kubectl apply -f deepseek-lws.yaml
```
Just to be sure, you can clean up using `kubectl delete -f deepseek-lws.yaml` and use `kubectl get pods` to make sure all the pods are gone before you run `kubectl apply`.

**Happy Hacking!!**

## Bonus

If you were keen observer and noticed that we forwarded port `8265` as well, point your browser to look at the Ray dashboard! 

- http://localhost:8265/#/overview
- http://localhost:8265/#/cluster

You can see the GPU usage specifically when you are running an inference.

## Thanks

A significant portion of this post is based on [Bryant Biggs](bryantbiggs)'s work in various repositories, thanks Bryant. Also thanks to Arush Sharma](https://github.com/rushmash91) for a quick review and suggestions.

## Things to try

As mentioned earlier we are relying here on a host node directory to persist model downloads across pod restarts. There are other options you can try as well, see the mozilla.ai link below that uses Persistent Volumes for example. Yet another option to store/load the model is using The [FSx for Lustre Container Storage Interface (CSI) driver](https://docs.aws.amazon.com/eks/latest/userguide/fsx-csi.html). 

`terraform-aws-eks-blueprints` [github repo](https://github.com/aws-ia/terraform-aws-eks-blueprints/tree/main/patterns/multi-node-vllm
) has a terraform based setup you can try too.

## Links
- https://huggingface.co/deepseek-ai/DeepSeek-V3
- https://www.theriseunion.com/en/blog/DeepSeek-V3-R1-671B-GPU-Requirements.html
- https://blog.mozilla.ai/deploying-deepseek-v3-on-kubernetes/
- https://github.com/aws-samples/deepseek-using-vllm-on-eks
- https://community.aws/content/2sJofoAecl6jVdDwVqglbZwKz2E
- https://docs.vllm.ai/en/latest/serving/distributed_serving.html
- https://github.com/vllm-project/vllm/issues/11539
- https://community.aws/content/2sJofoAecl6jVdDwVqglbZwKz2E/hosting-deepseek-r1-on-amazon-eks
- https://apxml.com/posts/gpu-requirements-deepseek-r1
- https://unsloth.ai/blog/deepseekr1-dynamic
- https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/machine-learning/multi-node-vllm/#dockerfile
- https://github.com/aws-ia/terraform-aws-eks-blueprints/blob/main/patterns/multi-node-vllm/Dockerfile
- https://github.com/aws-samples/sagemaker-genai-hosting-examples/blob/main/Deepseek/DeepSeek-R1-LMI-FP8.ipynb
- https://community.aws/content/2sJofoAecl6jVdDwVqglbZwKz2E/hosting-deepseek-r1-on-amazon-eks
- https://docs.aws.amazon.com/eks/latest/userguide/machine-learning-on-eks.html
