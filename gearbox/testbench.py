import math
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CLK_PERIOD_NS = 1
BITS_PER_BYTE = 8
BYTE_MASK = 0xFF


def signal_byte_width(signal):
    return len(signal.value) // BITS_PER_BYTE


def bytes_to_word(data):
    word = 0
    for idx, byte in enumerate(data):
        word |= byte << (BITS_PER_BYTE * idx)
    return word


def word_to_bytes(word, width):
    return [(word >> (BITS_PER_BYTE * idx)) & BYTE_MASK for idx in range(width)]


def signal_to_int(signal, name):
    try:
        return int(signal.value)
    except ValueError as exc:
        raise AssertionError(f"{name} has unresolved bits: {signal.value}") from exc


def aligned_input_beats(input_bytes_per_beat, output_bytes_per_beat, min_beats):
    beat_alignment = output_bytes_per_beat // math.gcd(
        input_bytes_per_beat,
        output_bytes_per_beat,
    )
    return beat_alignment * math.ceil(min_beats / beat_alignment)


def input_bytes_for_beat(beat_idx, input_bytes_per_beat):
    return [
        ((beat_idx * input_bytes_per_beat + byte_idx) * 37 + 11) & BYTE_MASK
        for byte_idx in range(input_bytes_per_beat)
    ]


async def reset_dut(dut):
    dut.rstn.value = 0
    dut.input_stream_valid.value = 0
    dut.output_stream_ready.value = 0
    dut.input_stream_data.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)

    dut.rstn.value = 1
    await RisingEdge(dut.clk)


async def run_stream_case(
    dut,
    name,
    min_input_beats,
    valid_probability,
    ready_probability,
    seed,
):
    input_bytes_per_beat = signal_byte_width(dut.input_stream_data)
    output_bytes_per_beat = signal_byte_width(dut.output_stream_data)
    input_beats = aligned_input_beats(
        input_bytes_per_beat,
        output_bytes_per_beat,
        min_input_beats,
    )
    expected_total_bytes = input_beats * input_bytes_per_beat

    rng = random.Random(seed)
    expected = deque()
    held_valid = False
    held_bytes = []
    held_word = 0
    sent_beats = 0
    received_bytes = 0
    cycle = 0
    max_cycles = max(200, input_beats * 30)

    await reset_dut(dut)

    while received_bytes < expected_total_bytes:
        if not held_valid and sent_beats < input_beats:
            held_valid = rng.random() < valid_probability
            if held_valid:
                held_bytes = input_bytes_for_beat(sent_beats, input_bytes_per_beat)
                held_word = bytes_to_word(held_bytes)

        # Drive stimulus immediately after a posedge and hold it stable until
        # the next posedge, where the DUT samples the handshake.
        dut.input_stream_valid.value = int(held_valid)
        dut.input_stream_data.value = held_word if held_valid else 0

        draining = sent_beats >= input_beats and not held_valid
        ready_probability_now = 1.0 if draining else ready_probability
        dut.output_stream_ready.value = int(rng.random() < ready_probability_now)

        await Timer(1, unit="ps")

        input_stream_ready = signal_to_int(dut.input_stream_ready, "input_stream_ready")
        output_stream_valid = signal_to_int(dut.output_stream_valid, "output_stream_valid")
        output_stream_ready = signal_to_int(dut.output_stream_ready, "output_stream_ready")

        input_handshake = held_valid and input_stream_ready
        output_handshake = output_stream_valid and output_stream_ready

        if input_handshake:
            expected.extend(held_bytes)
            sent_beats += 1
            held_valid = False
            held_bytes = []
            held_word = 0

        if output_handshake:
            actual_word = signal_to_int(dut.output_stream_data, "output_stream_data")
            actual_bytes = word_to_bytes(actual_word, output_bytes_per_beat)
            assert len(expected) >= output_bytes_per_beat, (
                f"{name}: DUT produced an output with only "
                f"{len(expected)} expected bytes queued"
            )
            expected_bytes = [expected.popleft() for _ in range(output_bytes_per_beat)]
            assert actual_bytes == expected_bytes, (
                f"{name}: output byte mismatch at byte {received_bytes}: "
                f"got {actual_bytes}, expected {expected_bytes}"
            )
            received_bytes += output_bytes_per_beat

        await RisingEdge(dut.clk)

        cycle += 1
        assert cycle < max_cycles, (
            f"{name}: timed out after {cycle} cycles; sent {sent_beats}/"
            f"{input_beats} beats and received {received_bytes}/"
            f"{expected_total_bytes} bytes"
        )

    assert not expected, f"{name}: scoreboard still has {len(expected)} bytes queued"

    for _ in range(3):
        dut.input_stream_valid.value = 0
        dut.input_stream_data.value = 0
        dut.output_stream_ready.value = 1
        await Timer(1, unit="ps")
        assert signal_to_int(dut.output_stream_valid, "output_stream_valid") == 0, (
            f"{name}: output_stream_valid remained asserted after all expected bytes drained"
        )
        await RisingEdge(dut.clk)


@cocotb.test()
async def byte_stream_regression(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    await run_stream_case(
        dut,
        name="continuous",
        min_input_beats=40,
        valid_probability=1.0,
        ready_probability=1.0,
        seed=0xC001,
    )

    await run_stream_case(
        dut,
        name="random_backpressure",
        min_input_beats=120,
        valid_probability=0.70,
        ready_probability=0.55,
        seed=0xACE5,
    )
