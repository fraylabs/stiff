.PHONY: check build run test mistakes verdict
check:
	python3 tasks.py check
build:
	python3 tasks.py build
run: build
	mkdir -p ../../.cache/bookings/state
	../../.cache/bookings/bookings --threads 2 ../../.cache/bookings/state/bookings.db 8080
test: build
	python3 tasks.py test
mistakes:
	python3 tasks.py mistakes
verdict:
	python3 tasks.py verdict
