#!/bin/bash

export CLUSTER_NAME=$(aws eks list-clusters --region $AWS_REGION --output text | awk '{print $2}')
export SECURITY_GROUP_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.securityGroupIds" --output text)


# Create the IAM role
aws iam create-role \
  --role-name eks-node-group-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# Attach the required policies to the role
aws iam attach-role-policy \
  --role-name eks-node-group-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy \
  --role-name eks-node-group-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

aws iam attach-role-policy \
  --role-name eks-node-group-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam attach-role-policy \
  --role-name eks-node-group-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess


# Create the Launch Template
aws ec2 create-launch-template \
  --launch-template-name eks-p4d-node-group-launch-template \
  --launch-template-data '{
    "BlockDeviceMappings": [
      {
        "DeviceName": "/dev/xvda",
        "Ebs": {
          "Iops": 16000,
          "VolumeSize": 2048,
          "VolumeType": "io2"
        }
      }
    ],
    "MetadataOptions": {
      "HttpPutResponseHopLimit": 2,
      "HttpTokens": "required"
    },
    "SecurityGroupIds": ["'$SECURITY_GROUP_ID'"]
  }'


# Create the EKS Managed Node Group
aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name p4d-nodegroup \
  --subnets $(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.subnetIds" --output text) \
  --node-role arn:aws:iam::086752300739:role/eks-node-group-role \
  --scaling-config minSize=1,maxSize=3,desiredSize=3 \
  --ami-type AL2023_x86_64_NVIDIA \
  --instance-types p4d.24xlarge \
  --launch-template name=eks-p4d-node-group-launch-template
