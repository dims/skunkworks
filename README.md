Notes
=====

eksdemo create cluster testing-deep-seek-qwen-32b -v "1.32" --instance p4d.24xlarge --max 1 --nodes 1 --no-taints

eksdemo delete cluster testing-deep-seek-qwen-32b

kubectl port-forward svc/deepseek-r1-server 8000:8000
