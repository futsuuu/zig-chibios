FROM ubuntu:latest

RUN <<EOF
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  xz-utils \
  qemu-system-riscv32
EOF

RUN mkdir -p work
WORKDIR /work

RUN <<EOF
curl -o zig.tar.xz -L https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz
mkdir -p zig
tar -xvf zig.tar.xz -C ./zig --strip-components 1
mv zig/lib /usr/lib/zig
mv zig/zig /usr/bin/zig
rm -rf zig zig.tar.xz
EOF

RUN curl -LO https://github.com/qemu/qemu/raw/v10.1.2/pc-bios/opensbi-riscv32-generic-fw_dynamic.bin

COPY build.zig .
COPY build.zig.zon .
COPY src ./src
COPY disk ./disk
RUN zig build --release
