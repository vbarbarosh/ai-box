docker run --rm -it -v $PWD:/app -v $PWD/.git:/app/.git:ro -v /host/repos:/repos:ro myimage

- goal: find replacemeent which allows executing docker inside
- i want to run `docker run ... ` inside
- i want to run `docker build ... ` inside
- i want to run `docker compose ... ` inside
- currently it does not allow run docker inside
- instead of docker it could be anything, but semantics should match
- it should open in less than 1sec
- when terminated - entire created environment should gone
- host should not be exposed at all: no --privileged no docker socket
