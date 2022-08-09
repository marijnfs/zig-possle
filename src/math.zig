const std = @import("std");

const dht = @import("dht");
const hex = dht.hex;

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
            break;
        }
    }

    if (zero_bits > id.len * 8 - 4) {
        std.log.debug("Error, failure in log calculation, too many zeroes in distance: {}", .{hex(&id)});
        return 0;
    }

    var int_value: u32 = 0;
    var int_representation = std.mem.asBytes(&int_value);

    var i: usize = 0;
    while (i < @sizeOf(u32)) : (i += 1) {
        const byte_index = zero_bits / 8 + i;
        const bit_index = @intCast(u3, zero_bits % 8);
        const repr_index = @sizeOf(u32) - 1 - i;
        int_representation[repr_index] = (id[byte_index] << bit_index);
        if (bit_index > 0)
            // int_representation[i] += (id[byte_index + 1] >> @intCast(u3, 7 - bit_index + 1));
            int_representation[repr_index] += (id[byte_index + 1] >> @intCast(u3, 7 - bit_index + 1));
    }

    const factor = @intToFloat(f64, int_value) / std.math.pow(f64, 2, @sizeOf(u32) * 8 - 1);

    //todo, create the floating point such that 2**n * 1.xxxx can be calculated
    //we know n, need to get 1.xxxx so we can get log(2**n * 1.xxxx) = n + log(1.xxxx)
    return @intToFloat(f64, 255 - zero_bits) + std.math.log(f64, 2, factor);
}
