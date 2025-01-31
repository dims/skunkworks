#!/usr/bin/env python

import openai
import pprint

client = openai.Client(
    base_url="http://127.0.0.1:8000/v1", api_key="EMPTY")

# Get the Models
models = client.models.list()
print(models)

# Chat completion
response = client.chat.completions.create(
    model=models.data[0].id,
    messages=[
        {
            "role": "user",
            "content": "What is Kubernetes?"
        },
    ]
)
print(response)
