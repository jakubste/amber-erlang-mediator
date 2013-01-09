REBAR      = ./rebar
C_SRC      = apps/amber/c_src


.PHONY: all clean allclean test dialyzer deps gen drivers roboclaw_driver amber_proto

## rebar wrappers ##############################################################
fast:
	$(REBAR) -j 5 skip_deps=true compile

all: deps drivers
	$(REBAR) -j 5 compile

deps:
	$(REBAR) -j 5 get-deps

clean:
	$(REBAR) -j 5 skip_deps=true clean

allclean:
	$(REBAR) -j 5 clean

gen: deps
	$(REBAR) generate

test:
	$(REBAR) -j 5 skip_deps=true eunit

dialyzer:
	dialyzer -I apps/*/include --statistics -Wunderspecs --src apps/*/src

## drivers' compilation ########################################################

drivers: roboclaw_driver

roboclaw_driver: amber_proto roboclaw.proto
	bash le_compiler.sh roboclaw "roboclaw_lib/*.cpp" roboclaw_lib

amber_proto:
	protoc -I=$(C_SRC)/protobuf --cpp_out=$(C_SRC)/protobuf $(C_SRC)/protobuf/drivermsg.proto

%.proto:
	protoc -I=$(C_SRC)/$(@:%.proto=%)/protobuf -I=$(C_SRC)/protobuf --cpp_out=$(C_SRC)/$(@:%.proto=%)/protobuf $(C_SRC)/$(@:%.proto=%)/protobuf/$@