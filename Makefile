REBAR := $(CURDIR)/rebar3

.PHONY: all
all: es

$(REBAR):
	@curl -k -f -L "https://github.com/emqx/rebar3/releases/download/3.14.3-emqx-7/rebar3" -o ./rebar3
	@chmod +x ./rebar3

.PHONY: compile
compile: $(REBAR)
	$(REBAR) compile

.PHONY: clean
clean: distclean

.PHONY: distclean
distclean:
	@rm -rf rebar3 _build erl_crash.dump rebar3.crashdump src/hocon_parser.erl src/hocon_scanner.erl

.PHONY: xref
xref:
	$(REBAR) xref

.PHONY: eunit
eunit: compile
	$(REBAR) eunit -v -c
	$(REBAR) cover

.PHONY: ct
ct: compile
	$(REBAR) as test ct -v

cover:
	$(REBAR) cover

.PHONY: dialyzer
dialyzer: compile
	$(REBAR) dialyzer

.PHONY: es
es: export HOCON_ESCRIPT = true
es: $(REBAR)
	$(REBAR) as es escriptize

.PHONY: elvis
elvis:
	./scripts/elvis-check.sh

.PHONY: fmt erlfmt
fmt: erlfmt
erlfmt: $(REBAR)
	$(REBAR) fmt -w

.PHONY: erlfmt-check
erlfmt-check: $(REBAR)
	$(REBAR) fmt -c
