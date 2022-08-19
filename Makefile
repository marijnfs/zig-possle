all:
	zig build
release:
	zig build -Drelease-fast
