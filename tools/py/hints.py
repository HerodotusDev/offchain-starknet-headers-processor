def write_word_to_memory(word: int, n: int, memory, ap) -> None:
    assert word < 2 ** (8 * n), f"Word value {word} exceeds {8 * n} bits."
    word_bytes = word.to_bytes(n, byteorder="big")
    for i in range(n):
        memory[ap + i] = word_bytes[i]


def print_u256(x, name):
    value = x.low + (x.high << 128)
    print(f"{name} = {hex(value)}")


def write_uint256_array(memory, ptr, array):
    for i, uint in enumerate(array):
        memory[ptr._reference_value + 2 * i] = uint[0]
        memory[ptr._reference_value + 2 * i + 1] = uint[1]
