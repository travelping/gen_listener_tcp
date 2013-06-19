.PHONY: compile test dialyzer clean

APPS = kernel stdlib

compile: rebar
	@./rebar compile

test: rebar
	@./rebar eunit

dialyzer: build.plt compile
	dialyzer --plt $< ebin

build.plt:
	dialyzer -q --build_plt --apps $(APPS) --output_plt $@

clean: rebar
	@./rebar clean

rebar:
	@wget -q http://cloud.github.com/downloads/basho/rebar/rebar
	@chmod u+x rebar
