#!/bin/sh
set -eu

if [ ! -f pcg-c/src/Makefile ]; then
  git submodule update --init --recursive
fi
