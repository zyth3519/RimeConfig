#!/bin/bash

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 version1 version2"
    echo "Example: $0 v13.1.0 13.0.7"
    exit 1
fi

version1="${1#v}"  
version2="${2#v}"

IFS='.' read -r -a v1_parts <<< "$version1"
IFS='.' read -r -a v2_parts <<< "$version2"

max_len=$(( ${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]} ))

for (( i=0; i < max_len; i++ )); do
    num1="${v1_parts[i]:-0}"
    num2="${v2_parts[i]:-0}"

    if (( num1 > num2 )); then
        echo 1
        exit 1  
    elif (( num1 < num2 )); then
        echo 2
        exit 2  
    fi
done

echo 0
exit 0 

