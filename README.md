# zig-chibios

A toy OS based on [Operating System in 1,000 Lines](https://operating-system-in-1000-lines.vercel.app/en/).

## Development

```
zig build run
```

Dependencies:

- Zig
- QEMU for 32bit RISC-V (qemu-system-riscv32)

## References

- [RISC-V SBI Specification](https://docs.riscv.org/reference/sbi/index.html)
- [VirtIO Devices - QEMU documentation](https://www.qemu.org/docs/master/system/devices/virtio/index.html)
    - [Virtual I/O Device (VIRTIO) Version 1.3](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.pdf)

## License

MIT
