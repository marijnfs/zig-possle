const std = @import("std");

const dht = @import("dht");

//calculate log2 of an ID
pub fn log2(id: dht.ID) f64 {
    var zero_bits: usize = 0;

    for (id) |byte| {
        if (byte == 0) {
            zero_bits += 8;
        } else {
            var half: u8 = 128;
            while (byte < half) {
                zero_bits += 1;
                half /= 2;
            }
        }
    }

    var int_representation: [4]u8 = undefined;
    var i: usize = 0;
    while (i < int_representation.len) : (i += 1) {
        const byte_index = zero_bits / 8 + i;
        const bit_index = @intCast(u3, zero_bits % 8);
        int_representation[i] = (id[byte_index] << bit_index);
        if (bit_index > 0)
            int_representation[i] += (id[byte_index + 1] >> @intCast(u3, 7 - bit_index + 1));
    }

    //todo, create the floating point such that 2**n * 1.xxxx can be calculated
    //we know n, need to get 1.xxxx so we can get log(2**n * 1.xxxx) = n + log(1.xxxx)
    return @intToFloat(f64, zero_bits);
}
