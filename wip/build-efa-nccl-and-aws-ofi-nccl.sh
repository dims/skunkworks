#!/usr/bin/env bash

export AWS_OFI_NCCL_VERSION=1.13.2-aws
export EFA_INSTALLER_VERSION=1.38.0
export NCCL_VERSION=2.24.3

apt update
apt install -y \
    libhwloc-dev \
    pciutils \

# EFA installer
cd /tmp
curl -sL "https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz" | tar xvz
cd aws-efa-installer

./efa_installer.sh --yes --skip-kmod --skip-limit-conf --no-verify --mpi openmpi5

echo "/opt/amazon/openmpi5/lib" > /etc/ld.so.conf.d/openmpi.conf
ldconfig

# NCCL
cd /tmp
[ ! -d "nccl" ] && rm -rf "nccl"
git clone https://github.com/NVIDIA/nccl.git -b v${NCCL_VERSION}-1
cd nccl
rm /opt/nccl/lib/*.a

make -j $(nproc) src.build \
  BUILDDIR=/opt/nccl \
  CUDA_HOME=/usr/local/cuda \
  NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86 -gencode=arch=compute_86,code=sm_86"

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

cd /tmp
tar -cvzf efa-nccl-and-aws-ofi-nccl.tgz \
  /etc/ld.so.conf.d/000_efa.conf \
  /etc/ld.so.conf.d/openmpi.conf \
  /etc/ld.so.conf.d/000_nccl.conf \
  /etc/ld.so.conf.d/000-aws-ofi-nccl.conf \
  /opt/amazon \
  /opt/aws-ofi-nccl \
  /opt/nccl/lib

pip install awscli
aws s3 cp efa-nccl-and-aws-ofi-nccl.tgz s3://dims-deepseek-ai/

