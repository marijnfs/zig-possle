# Proof of Space Search with Logarithmic Embargo (PoSS-LE)
Author: Marijn Stollenga
License: MPL-V2 (see LICENSE file)

This is an implementation of PoSSLE, a simple Proof of Space Consensus algorithm that avoids the Nothing-at-State problem and creates stable block times using a Logarithmic Embargo.

Read the paper here: [](placeholder)

# Build

Type:
`make release`

This uses a makefile but simply calls `zig build -Drelease-fast`

# Plot
Create a plot of 4 Gigabytes using:

`./zig-out/bin/plotter --tmp .tmp --out main.db --basesize 64M --persistent_basesize 1G --size 4G --n_threads 15`

# Index
Index the plot using

`./zig-out/bin/indexer --plot_path main.db --index_output main.index`

# Farming
Start a farmer using
`./zig-out/bin/miner --ip 0.0.0.0 --port 7000 --plot_path main.db --index_path main.index --req_thread 1`

