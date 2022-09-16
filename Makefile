deploy/transcoder: stack-docker-image
	rm -f deploy/transcoder
	stack install --no-haddock $(STACK_ARGS) --docker --local-bin-path deploy

stack-docker-image:
	docker pull "fpco/stack-build:$$(./print-stack-resolver)"
