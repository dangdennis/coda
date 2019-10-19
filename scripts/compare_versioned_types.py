#!/usr/bin/env python3

# compare representations of versioned types in OCaml files

# expects two Ocaml files possibly containing versioned types
#
# the first file is the original, the second is the modified file

# for each file, we create a dictionary mapping module-paths to the type definitions
# since we want to detect changes, we run this algorithm
#   for each type definition td in the first file
#     if td from the second file is different, there's an error
#     if there is no td in the second file, that's OK (we can't serialize that type)
# new type definitions in the second file are OK, we didn't change an existing serialization

import os
import sys
import subprocess
import tempfile

exit_code = 0

def create_dict (types_file) :
    with open (types_file, 'r') as fp :
        types = {}
        line = fp.readline()
        while line:
            line = line.strip (' \n')
            fields = line.split(':',1)
            types[fields[0]] = fields[1]
            line = fp.readline()
        return types
        
# expects files containing lines of the form
#  path:type_definition
def compare_types (original,modified) :
    types_orig = create_dict (original)
    types_mod = create_dict (modified)
    for path in types_orig :
        orig = types_orig[path]
        mod = types_mod[path]
        if not (mod is None or mod == orig) :
            print ("Versioned type differs at path " + path)
            print ("  Originally: " + orig)
            print ("  Changed to: " + mod)
            global exit_code
            exit_code = 1
    exit (exit_code)            

def create_types_file (ocaml,out_dir) :
    os.mkdir (out_dir)
    out_fn = out_dir + ocaml
    types_fn= out_fn + '.types'
    subprocess.run(['./scripts/apply_versioned_module.sh',ocaml,out_fn])
    with open (types_fn, 'w') as fp :
        subprocess.run(['src/_build/default/lib/print_versioned_types/print_versioned_types.exe',out_fn,'-o','/dev/null'],stdout=fp)
    return types_fn
        
def main (original,modified) :
    orig_dir='original'
    mod_dir='modified'
    orig_types = create_types_file (original,orig_dir)
    mod_types = create_types_file (modified,mod_dir)
    compare_types (orig_types,mod_types)
    
if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: %s original.ml modified.ml" % sys.argv[0], file=sys.stderr)
        print("The .ml files must have the same name, with different paths")
        sys.exit(1)

    main(sys.argv[1],sys.argv[2])
