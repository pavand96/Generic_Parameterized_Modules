# Gearbox WaveDrom Examples

These examples show the intended rdy/vld behavior for the gearbox strm
interface. They can be pasted into the WaveDrom editor or rendered by markdown
tooling that supports `wavedrom` code blocks.

## In Handshake

An in beat is accepted only when `in_strm_vld` and
`in_strm_rdy` are both high on the same rising clock edge. The producer
must hold `in_strm_data` stable while `in_strm_vld` is high and the
gearbox is not rdy.

```wavedrom
{
  signal: [
    { name: "clk",                wave: "p..........." },
    { name: "in_strm_vld", wave: "01..0.1..0.." },
    { name: "in_strm_rdy", wave: "1.0.1.0.1..." },
    { name: "in_strm_data",  wave: "x=..x.=..x..", data: ["A0", "A1"] },
    { name: "in handshake",    wave: "0...1....1..", node: "....a....b.." }
  ],
  edge: [
    "a~>b accepted in beats"
  ]
}
```

## Output Backpressure

When `out_strm_vld` is high and `out_strm_rdy` is low,
`out_strm_data` remains stable. The output beat transfers when both
signals are high.

```wavedrom
{
  signal: [
    { name: "clk",                 wave: "p..........." },
    { name: "out_strm_vld", wave: "0.1....0.1.." },
    { name: "out_strm_rdy", wave: "1..0..1..1.." },
    { name: "out_strm_data",  wave: "x.=....x.=..", data: ["B0", "B1"] },
    { name: "output handshake",    wave: "0.....1...1." }
  ]
}
```

## Packing Smaller In Beats Into Larger Output Beats

For `IN_DATA_WIDTH=24` and `OUT_DATA_WIDTH=40`, the derived shape is three
8-bit in chunks per beat and five 8-bit output chunks per beat. The output
strm does not assert vld until enough in chunks are stored to form one complete
output beat.

```wavedrom
{
  signal: [
    { name: "clk",                 wave: "p..............." },
    { name: "in_strm_vld",  wave: "01.01.01.0....." },
    { name: "in_strm_rdy",  wave: "1.............." },
    { name: "in_strm_data",   wave: "x=.x=.x=.x.....", data: ["I0[2:0]", "I1[2:0]", "I2[2:0]"] },
    { name: "stored chunks",        wave: "x=.=.=.=.=.....", data: ["0", "3", "6", "4", "7"] },
    { name: "out_strm_vld", wave: "0...1.0.1....." },
    { name: "out_strm_rdy", wave: "1.............." },
    { name: "out_strm_data",  wave: "x...=.x.=.....", data: ["O0[4:0]", "O1[4:0]"] }
  ]
}
```

## Random Backpressure Test Shape

The cocotb testbench randomly toggles in vld and output rdy. The
scoreboard only updates on handshakes, so stalls do not change expected chunk
ordering.

```wavedrom
{
  signal: [
    { name: "clk",                 wave: "p................" },
    { name: "in_strm_vld",  wave: "01.0.1..01.0...." },
    { name: "in_strm_rdy",  wave: "1..01.0..1.01..." },
    { name: "in handshake",     wave: "0...10...1......" },
    { name: "out_strm_vld", wave: "0....1....01...." },
    { name: "out_strm_rdy", wave: "1.0..1.0...1...." },
    { name: "output handshake",    wave: "0....1.....1...." }
  ]
}
```
