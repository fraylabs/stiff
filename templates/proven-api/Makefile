.PHONY: setup check build run mistakes
setup:
	python3 tasks.py setup
check:
	python3 tasks.py check
build:
	python3 tasks.py build
PORT ?= 8080
run: build
	./build/@NAME@ --threads 2 $(PORT)
mistakes:
	python3 tasks.py mistakes
