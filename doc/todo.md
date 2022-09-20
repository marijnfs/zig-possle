#Todos:
Todo:
- Save index file to disk
- Currently zig dht threads just go forever, and segfault when server is close
  - Make sure the server can be ended and joined on (atomic bool to stop can work)
- Output File needs to exist, seems realpath needs existing file
- Program unreliably runs out of memory somehow

- Write graph block struct that keeps track and validates blocks
    - Also keeps track of current head block


Done:
v verification through construction.
 v to more easily validate new block, reproduce it from the ingredients and check that it fits.
v Implement simple miner p2p code that servers as experiment
  v Simple commit a message to each block, print it for each recieved block
v Make miner usable from command line
v Make plotter code usable from command line
v Implement file-based PersistentMergePlotter
v Implement log(n) log(n) search strategy
v Implement log(n) binary trie strategy
