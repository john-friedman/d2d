# rewriting doc2dict by forking selectolax

1. This is fun af
2. Thank you Alex and Artem.

this is a scratch repo, will rename / reformat / productionize later on. the goal is to prove >100mb/s single threaded html to dict throughput. This means parsing the entire SEC html corpus on a 16 thread laptop should take ~1.5 hours.

# Core
1. convert file to instructions list (e.g. just stream data without computations)
2. normalize instructions list (e.g. merge instructions)
3. convert instructions list to data tuples (maybe rename data tuples, but basically columnar representation of dict)

## utils

- convert data tuples to dict
- convert dict to data tuples
- flattnes, etc wll think

# terminology
adapters
- html
- pdf
normalizers
transformers

## mapping dicts

adapter
normalizer - when to merge e.g. text
transformer - how to construct nesting





# speedups
use noi directly

parser - can we kill unneeded parts - doesnt look like it...
node - same? - yep call c api directly
traverse -YES, use as a pure cython util means traverse + signals is 14ms, 18ms, current.


so looks like
4ms load
66ms parse
18ms to do traverse


extract attributes to file time: 0.08496580000064569 (84ms)
extract_all_attributes  to seperate out file io (28ms)
-hmm thats our main sink, can we make it smaller.

huh so we could just stream to file with buffers ? hopefully ~30ms

that would mean
4
66
16ms!
86ms total to generatre instructions list or so + a bit for other stuff