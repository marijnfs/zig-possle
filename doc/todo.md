#Todos:

- Currently zig dht threads just go forever, and segfault when server is close
  - Make sure the server can be ended and joined on (atomic bool to stop can work)
- Output File needs to exist, seems realpath needs existing file
- Program unreliably runs out of memory somehow

- Implement simple miner p2p code that servers as experiment
  - Simple commit a message to each block, print it for each recieved block
  - Write graph block struct that keeps track and validates blocks
    - Also keeps track of current head block
- Make miner usable from command line
- Make plotter code usable from command line
- Implement file-based PersistentMergePlotter
- Implement log(n) log(n) search strategy
- Implement log(n) binary trie strategy
