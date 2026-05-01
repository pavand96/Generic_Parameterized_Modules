import math
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CLK_PERIOD_NS = 1


def byte_width(signal):
    return len(signal.value) // 8


def bytes_to_word(data):
    word = 0
    for idx, byte in enumerate(data):
        word |= byte << (8 * idx)
    return word


def word_to_bytes(word, width):
    return [(word >> (8 * idx)) & 0xFF for idx in range(width)]


def signal_int(signal, name):
    try:
        return int(signal.value)
    except ValueError as exc:
        raise AssertionError(f"{name} has unresolved bits: {signal.value}") from exc


def aligned_input_beats(in_db, out_db, min_beats):
    beat_granularity = out_db // math.gcd(in_db, out_db)
    return beat_granularity * math.ceil(min_beats / beat_granularity)


def input_bytes_for_beat(beat_idx, in_db):
    return [((beat_idx * in_db + byte_idx) * 37 + 11) & 0xFF for byte_idx in range(in_db)]


async def reset_dut(dut):
    dut.rstn.value = 0
    dut.valid_in.value = 0
    dut.ready_in.value = 0
    dut.data_in.value = 0

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
    in_db = byte_width(dut.data_in)
    out_db = byte_width(dut.data_out)
    input_beats = aligned_input_beats(in_db, out_db, min_input_beats)
    expected_total_bytes = input_beats * in_db

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
                held_bytes = input_bytes_for_beat(sent_beats, in_db)
                held_word = bytes_to_word(held_bytes)

        # Drive stimulus immediately after a posedge and hold it stable until
        # the next posedge, where the DUT samples the handshake.
        dut.valid_in.value = int(held_valid)
        dut.data_in.value = held_word if held_valid else 0

        draining = sent_beats >= input_beats and not held_valid
        ready_probability_now = 1.0 if draining else ready_probability
        dut.ready_in.value = int(rng.random() < ready_probability_now)

        await Timer(1, unit="ps")

        ready_out = signal_int(dut.ready_out, "ready_out")
        valid_out = signal_int(dut.valid_out, "valid_out")
        ready_in = signal_int(dut.ready_in, "ready_in")

        in_fire = held_valid and ready_out
        out_fire = valid_out and ready_in

        if in_fire:
            expected.extend(held_bytes)
            sent_beats += 1
            held_valid = False
            held_bytes = []
            held_word = 0

        if out_fire:
            actual_word = signal_int(dut.data_out, "data_out")
            actual_bytes = word_to_bytes(actual_word, out_db)
            assert len(expected) >= out_db, (
                f"{name}: DUT produced an output with only "
                f"{len(expected)} expected bytes queued"
            )
            expected_bytes = [expected.popleft() for _ in range(out_db)]
            assert actual_bytes == expected_bytes, (
                f"{name}: output byte mismatch at byte {received_bytes}: "
                f"got {actual_bytes}, expected {expected_bytes}"
            )
            received_bytes += out_db

        await RisingEdge(dut.clk)

        cycle += 1
        assert cycle < max_cycles, (
            f"{name}: timed out after {cycle} cycles; sent {sent_beats}/"
            f"{input_beats} beats and received {received_bytes}/"
            f"{expected_total_bytes} bytes"
        )

    assert not expected, f"{name}: scoreboard still has {len(expected)} bytes queued"

    for _ in range(3):
        dut.valid_in.value = 0
        dut.data_in.value = 0
        dut.ready_in.value = 1
        await Timer(1, unit="ps")
        assert signal_int(dut.valid_out, "valid_out") == 0, (
            f"{name}: valid_out remained asserted after all expected bytes drained"
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
