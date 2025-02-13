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

RUN <<EOT
  wget https://raw.githubusercontent.com/kubernetes-sigs/lws/main/docs/examples/vllm/build/ray_init.sh -O /ray_init.sh;
  chmod +x /ray_init.sh

  pip install huggingface_hub[hf_transfer]
EOT
