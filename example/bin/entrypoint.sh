#!/bin/bash

set -euo pipefail

# OSX does not support readlink '-f' flag, work
# around that
# shellcheck disable=SC2039
case $OSTYPE in
    darwin*)
        SCRIPT=$(readlink "$0" || true)
    ;;
    *)
        SCRIPT=$(readlink -f "$0" || true)
    ;;
esac

ERTS_VSN="{{ erts_vsn }}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd -P)"
RELEASE_ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CONFIG_DIR="$RELEASE_ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/example.hocon"

find_erts_dir() {
    __erts_dir="$RELEASE_ROOT_DIR/erts-$ERTS_VSN"
    if [ -d "$__erts_dir" ]; then
        ERTS_DIR="$__erts_dir";
    else
        __erl="$(command -v erl)"
        code="io:format(\"~s\", [code:root_dir()]), halt()."
        __erl_root="$("$__erl" -boot no_dot_erlang -sasl errlog_type error -noshell -eval "$code")"
        ERTS_DIR="$__erl_root/erts-$ERTS_VSN"
        if [ ! -d "$ERTS_DIR" ]; then
            erts_version_code="io:format(\"~s\", [erlang:system_info(version)]), halt()."
            __erts_version="$("$__erl" -boot no_dot_erlang -sasl errlog_type error -noshell -eval "$erts_version_code")"
            ERTS_DIR="${__erl_root}/erts-${__erts_version}"
            if [ -d "$ERTS_DIR" ]; then
                ERTS_VSN=${__erts_version}
                echo "Exact ERTS version (${ERTS_VSN}) match not found, instead using ${__erts_version}. The release may fail to run." 1>&2
            else
                echo "Can not run the release. There is no ERTS bundled with the release or found on the system."
                exit 1
            fi
        fi
    fi
}

## generate sys.config and vm.args
if [ "$CONFIG_FILE" -nt "$RELEASE_ROOT_DIR/sys.conf" ]; then
    find_erts_dir

    TIME="$("$ERTS_DIR/bin/escript" "$RELEASE_ROOT_DIR/bin/hocon" generate \
                --schema_module example_schema \
                --conf_file "$CONFIG_FILE" \
                --dest_dir "$CONFIG_DIR" \
                --pa "$RELEASE_ROOT_DIR/lib/example-0.1.0/ebin")"

    cp "$CONFIG_DIR/app.$TIME.config" "$RELEASE_ROOT_DIR/sys.config"
    cp "$CONFIG_DIR/vm.$TIME.args" "$RELEASE_ROOT_DIR/vm.args"
fi

exec "$SCRIPT_DIR/example" "$@"
