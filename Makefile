REBAR := rebar3

.PHONY: all
all: es

.PHONY: compile
compile:
	$(REBAR) compile

.PHONY: clean
clean: distclean

.PHONY: distclean
distclean:
	@rm -rf _build erl_crash.dump rebar3.crashdump src/hocon_parser.erl src/hocon_scanner.erl

.PHONY: xref
xref:
	$(REBAR) xref

.PHONY: eunit
eunit: compile
	$(REBAR) eunit -v

.PHONY: ct
ct: compile
	$(REBAR) as test ct -v

cover:
	$(REBAR) cover

.PHONY: dialyzer
dialyzer:
	$(REBAR) dialyzer

.PHONY: es
es: compile
	$(REBAR) escriptize
