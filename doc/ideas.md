Use Trie datastructure
Perhaps better than just sorted

Build Trie datastruct:


Basically index all data depth first
- First sort all data
- l = 0, r = N, m = first item when first bit is 1 (binary search)
left side: 
 	- l = l, r = m, first item where second bit is on
	- keep going
		- if l == r we have an end node
		- if l == m but not m == r; just continue with the right side
		- if r == m but not m == l; just continue with the left side
		- otherwise, make a node here
- do the same for right side l = m, r = r

Datastruct
[Node]
l: i32 ; index of next node for bit = 0
r: i32 ; index of next node for bit = 1

using i32 saves a lot of space for index, but limits the set size that can be indexed

each bud has a size of 32 * 2 bytes at the moment (seed + bud)
We need 2 * as many node entries as buds. With 32 bit this is 4x2 = 8 bytes per entry

If we use 31 bytes for adressing, and 1 bit for node / leaf distinction, we can address
2^31 = 2147483648 buds with have a size of 128 GB.
The index would be about 16GB, making a 'plot' 144GB.


Lookup would be log(n) which is nice.
