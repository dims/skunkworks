#!/bin/bash

# Create role
role_name="S3ReadRole"
echo '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowEksAuthToAssumeRoleForPodIdentity",
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}' > trust-policy.json
role_output=$(aws iam create-role --role-name $role_name --assume-role-policy-document file://trust-policy.json)
role_arn=$(echo $role_output | jq -r .Role.Arn)
echo '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::*"
      ]
    }
  ]
}' > s3-read-policy.json
aws iam put-role-policy --role-name $role_name --policy-name S3ReadPolicy --policy-document file://s3-read-policy.json
rm trust-policy.json s3-read-policy.json
echo "Role '$role_name' created with S3 read access."
echo "Role ARN: $role_arn"

# Create pod identity association
aws eks create-pod-identity-association --cluster-name $(eksctl get cluster -o json | jq -r '.[0].Name') \
  --namespace default \
  --service-account my-service-account \
  --role-arn arn:aws:iam::086752300739:role/S3ReadRole

# Cleanup
role_name="S3ReadRole"
aws iam delete-role-policy --role-name $role_name --policy-name S3ReadPolicy
aws iam delete-role --role-name $role_name

