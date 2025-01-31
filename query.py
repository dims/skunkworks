#!/usr/bin/env python

import openai
import pprint

client = openai.Client(
    base_url="http://127.0.0.1:8000/v1", api_key="EMPTY")

# Chat completion
response = client.chat.completions.create(
    model="deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    messages=[
        {
            "role": "user",
            "content": "What is Kubernetes?"
        },
    ]
)
print(response)
