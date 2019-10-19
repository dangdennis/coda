#!/bin/sh

# applies the %%versioned ppx to an OCaml file; useful for print_versioned_types

RUN_PPX_CODA=src/_build/default/lib/ppx_coda/run_ppx_coda.exe

if [ ! -f $RUN_PPX_CODA ] ; then
    echo "Could not find ppx driver at $RUN_PPX_CODA"
    exit 1
fi

if [ -z $1 ] ; then
    echo "Syntax: $0 input.ml [output.ml]"
    exit 1
fi

if [ ! -f $1 ] ; then
    echo "Could not find input OCaml file $1"
    exit 1
fi

if [ -z $2 ] ; then 
    $RUN_PPX_CODA -apply ppx_coda/versioned_module $1
else
    $RUN_PPX_CODA -apply ppx_coda/versioned_module $1 -o $2
fi
